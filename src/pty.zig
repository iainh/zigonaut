const std = @import("std");

const win = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

pub const Pty = struct {
    pseudo_console: win.HPCON,
    input: win.HANDLE,
    output: win.HANDLE,
    process: win.HANDLE,

    pub fn spawn(allocator: std.mem.Allocator, command: []const u8, columns: u16, rows: u16) !Pty {
        var input_read: win.HANDLE = null;
        var input_write: win.HANDLE = null;
        if (win.CreatePipe(&input_read, &input_write, null, 0) == 0) return windowsError();
        errdefer {
            _ = win.CloseHandle(input_read);
            _ = win.CloseHandle(input_write);
        }

        var output_read: win.HANDLE = null;
        var output_write: win.HANDLE = null;
        if (win.CreatePipe(&output_read, &output_write, null, 0) == 0) return windowsError();
        errdefer {
            _ = win.CloseHandle(output_read);
            _ = win.CloseHandle(output_write);
        }

        var pseudo_console: win.HPCON = null;
        const size = win.COORD{ .X = @intCast(columns), .Y = @intCast(rows) };
        if (win.CreatePseudoConsole(size, input_read, output_write, 0, &pseudo_console) < 0) {
            return error.CreatePseudoConsoleFailed;
        }
        errdefer win.ClosePseudoConsole(pseudo_console);

        _ = win.CloseHandle(input_read);
        input_read = null;
        _ = win.CloseHandle(output_write);
        output_write = null;

        var attribute_bytes: usize = 0;
        _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
        const attributes = win.HeapAlloc(win.GetProcessHeap(), 0, attribute_bytes) orelse return error.OutOfMemory;
        defer _ = win.HeapFree(win.GetProcessHeap(), 0, attributes);

        const attribute_list: win.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attributes);
        if (win.InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_bytes) == 0) {
            return windowsError();
        }
        defer win.DeleteProcThreadAttributeList(attribute_list);

        if (win.UpdateProcThreadAttribute(
            attribute_list,
            0,
            win.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            pseudo_console,
            @sizeOf(win.HPCON),
            null,
            null,
        ) == 0) return windowsError();

        var startup: win.STARTUPINFOEXW = std.mem.zeroes(win.STARTUPINFOEXW);
        startup.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
        startup.lpAttributeList = attribute_list;

        var process_info: win.PROCESS_INFORMATION = std.mem.zeroes(win.PROCESS_INFORMATION);
        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
        defer allocator.free(command_line);

        if (win.CreateProcessW(
            null,
            command_line.ptr,
            null,
            null,
            0,
            win.EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &startup.StartupInfo,
            &process_info,
        ) == 0) return windowsError();
        _ = win.CloseHandle(process_info.hThread);

        return .{
            .pseudo_console = pseudo_console,
            .input = input_write,
            .output = output_read,
            .process = process_info.hProcess,
        };
    }

    pub fn resize(self: *Pty, columns: u16, rows: u16) !void {
        const size = win.COORD{ .X = @intCast(columns), .Y = @intCast(rows) };
        if (win.ResizePseudoConsole(self.pseudo_console, size) < 0) return error.ResizePseudoConsoleFailed;
    }

    pub fn read(self: *Pty, buffer: []u8) !usize {
        var bytes_read: win.DWORD = 0;
        if (win.ReadFile(self.output, buffer.ptr, @intCast(buffer.len), &bytes_read, null) == 0) {
            const code = win.GetLastError();
            if (code == win.ERROR_BROKEN_PIPE or code == win.ERROR_OPERATION_ABORTED or code == win.ERROR_INVALID_HANDLE) return 0;
            return error.ReadPseudoConsoleFailed;
        }
        return bytes_read;
    }

    pub fn write(self: *Pty, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var bytes_written: win.DWORD = 0;
            if (win.WriteFile(
                self.input,
                bytes[offset..].ptr,
                @intCast(bytes.len - offset),
                &bytes_written,
                null,
            ) == 0) return error.WritePseudoConsoleFailed;
            if (bytes_written == 0) return error.WritePseudoConsoleFailed;
            offset += bytes_written;
        }
    }

    pub fn exitedCleanly(self: *const Pty) bool {
        if (win.WaitForSingleObject(self.process, 0) != win.WAIT_OBJECT_0) return false;
        var exit_code: win.DWORD = 0;
        return win.GetExitCodeProcess(self.process, &exit_code) != 0 and exit_code == 0;
    }

    pub fn stopIo(self: *Pty, reader_thread: ?std.Thread) void {
        _ = win.CloseHandle(self.input);
        if (reader_thread) |thread| _ = win.CancelSynchronousIo(@ptrCast(thread.getHandle()));
        _ = win.CancelIoEx(self.output, null);
        _ = win.CloseHandle(self.output);
    }

    pub fn closeConsole(self: *Pty) void {
        win.ClosePseudoConsole(self.pseudo_console);

        if (win.WaitForSingleObject(self.process, 2000) == win.WAIT_TIMEOUT) {
            _ = win.TerminateProcess(self.process, 1);
        }
    }

    pub fn finishClose(self: *Pty) void {
        _ = win.CloseHandle(self.process);
    }
};

fn windowsError() anyerror {
    return switch (win.GetLastError()) {
        win.ERROR_FILE_NOT_FOUND => error.ExecutableNotFound,
        win.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.WindowsApiFailure,
    };
}
