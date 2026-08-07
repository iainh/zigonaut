const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const win = win32.c;

const log = std.log.scoped(.pty);
const pipe_buffer_bytes = 128 * 1024;

const ConptyCreate = *const fn (win.COORD, win.HANDLE, win.HANDLE, win.DWORD, *win.HPCON) callconv(.winapi) win.HRESULT;
const ConptyResize = *const fn (win.HPCON, win.COORD) callconv(.winapi) win.HRESULT;
const ConptyRelease = *const fn (win.HPCON) callconv(.winapi) win.HRESULT;
const ConptyClose = *const fn (win.HPCON) callconv(.winapi) void;

const Conpty = struct {
    module: win.HMODULE,
    create: ConptyCreate,
    resize: ConptyResize,
    release: ConptyRelease,
    close: ConptyClose,

    fn load(allocator: std.mem.Allocator) !Conpty {
        // Use the matching side-by-side ConPTY files. The system version can
        // produce corrupt output when a resize changes rows and columns.
        const host_architecture = switch (builtin.cpu.arch) {
            .x86_64 => "x64",
            .aarch64 => "arm64",
            else => @compileError("side-by-side ConPTY supports only x86_64 and aarch64"),
        };
        const host_relative_path = switch (builtin.cpu.arch) {
            .x86_64 => std.unicode.utf8ToUtf16LeStringLiteral("x64\\OpenConsole.exe"),
            .aarch64 => std.unicode.utf8ToUtf16LeStringLiteral("arm64\\OpenConsole.exe"),
            else => unreachable,
        };

        const host_path = try win32.applicationFilePathAlloc(allocator, host_relative_path);
        defer allocator.free(host_path);
        const host_attributes = win.GetFileAttributesW(host_path.ptr);
        if (host_attributes == win.INVALID_FILE_ATTRIBUTES or host_attributes & win.FILE_ATTRIBUTE_DIRECTORY != 0) {
            log.err("bundled ConPTY host is missing ({s}\\OpenConsole.exe beside zigonaut.exe)", .{host_architecture});
            return error.ConptyHostNotFound;
        }

        const dll_path = try win32.applicationFilePathAlloc(
            allocator,
            std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
        );
        defer allocator.free(dll_path);
        const module = win.LoadLibraryExW(
            dll_path.ptr,
            null,
            win.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | win.LOAD_LIBRARY_SEARCH_APPLICATION_DIR | win.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse {
            log.err("bundled conpty.dll could not be loaded from beside zigonaut.exe", .{});
            return error.ConptyDllNotFound;
        };
        errdefer _ = win.FreeLibrary(module);

        const create = symbol(ConptyCreate, module, "ConptyCreatePseudoConsole") orelse return missingExport();
        const resize = symbol(ConptyResize, module, "ConptyResizePseudoConsole") orelse return missingExport();
        const release = symbol(ConptyRelease, module, "ConptyReleasePseudoConsole") orelse return missingExport();
        const close = symbol(ConptyClose, module, "ConptyClosePseudoConsole") orelse return missingExport();
        return .{ .module = module, .create = create, .resize = resize, .release = release, .close = close };
    }

    fn unload(self: *const Conpty) void {
        _ = win.FreeLibrary(self.module);
    }
};

pub const Pty = struct {
    conpty: Conpty,
    pseudo_console: win.HPCON,
    input: win.HANDLE,
    output: win.HANDLE,
    process: win.HANDLE,

    pub fn spawn(allocator: std.mem.Allocator, command: []const u8, working_directory: []const u8, columns: u16, rows: u16) !Pty {
        const conpty = try Conpty.load(allocator);
        errdefer conpty.unload();

        var input_read: win.HANDLE = null;
        var input_write: win.HANDLE = null;
        if (win.CreatePipe(&input_read, &input_write, null, pipe_buffer_bytes) == 0) return windowsError();
        errdefer {
            _ = win.CloseHandle(input_read);
            _ = win.CloseHandle(input_write);
        }

        var output_read: win.HANDLE = null;
        var output_write: win.HANDLE = null;
        if (win.CreatePipe(&output_read, &output_write, null, pipe_buffer_bytes) == 0) return windowsError();
        errdefer {
            _ = win.CloseHandle(output_read);
            _ = win.CloseHandle(output_write);
        }

        var pseudo_console: win.HPCON = null;
        const size = win.COORD{ .X = @intCast(columns), .Y = @intCast(rows) };
        if (conpty.create(size, input_read, output_write, 0, &pseudo_console) < 0) {
            return error.CreatePseudoConsoleFailed;
        }
        errdefer conpty.close(pseudo_console);

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
        startup.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES;
        startup.lpAttributeList = attribute_list;

        var process_info: win.PROCESS_INFORMATION = std.mem.zeroes(win.PROCESS_INFORMATION);
        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
        defer allocator.free(command_line);
        const user_profile = if (working_directory.len == 0)
            win32.environmentVariableAlloc(allocator, "USERPROFILE") catch null
        else
            null;
        defer if (user_profile) |profile| allocator.free(profile);
        const launch_directory = resolveWorkingDirectory(working_directory, user_profile orelse "");
        const current_directory = if (launch_directory.len == 0) null else try std.unicode.utf8ToUtf16LeAllocZ(allocator, launch_directory);
        defer if (current_directory) |directory| allocator.free(directory);

        if (win.CreateProcessW(
            null,
            command_line.ptr,
            null,
            null,
            0,
            win.EXTENDED_STARTUPINFO_PRESENT,
            null,
            if (current_directory) |directory| directory.ptr else null,
            &startup.StartupInfo,
            &process_info,
        ) == 0) return windowsError();
        _ = win.CloseHandle(process_info.hThread);
        if (conpty.release(pseudo_console) < 0) {
            // Stop the child because a failed release leaves ownership unknown.
            _ = win.TerminateProcess(process_info.hProcess, 1);
            _ = win.CloseHandle(process_info.hProcess);
            return error.ReleasePseudoConsoleFailed;
        }

        return .{
            .conpty = conpty,
            .pseudo_console = pseudo_console,
            .input = input_write,
            .output = output_read,
            .process = process_info.hProcess,
        };
    }

    pub fn resize(self: *Pty, columns: u16, rows: u16) !void {
        const size = win.COORD{ .X = @intCast(columns), .Y = @intCast(rows) };
        if (self.conpty.resize(self.pseudo_console, size) < 0) return error.ResizePseudoConsoleFailed;
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
        if (!self.exited()) return false;
        var exit_code: win.DWORD = 0;
        return win.GetExitCodeProcess(self.process, &exit_code) != 0 and exit_code == 0;
    }

    pub fn exited(self: *const Pty) bool {
        return win.WaitForSingleObject(self.process, 0) == win.WAIT_OBJECT_0;
    }

    pub fn cancelIo(self: *Pty, reader_thread: ?std.Thread, writer_thread: ?std.Thread) void {
        _ = self;
        if (reader_thread) |thread| _ = win.CancelSynchronousIo(@ptrCast(thread.getHandle()));
        if (writer_thread) |thread| _ = win.CancelSynchronousIo(@ptrCast(thread.getHandle()));
    }

    pub fn closeIo(self: *Pty) void {
        _ = win.CloseHandle(self.input);
        _ = win.CloseHandle(self.output);
    }

    pub fn closeConsole(self: *Pty) void {
        self.conpty.close(self.pseudo_console);

        // Give the shell two seconds to exit before forced termination.
        if (win.WaitForSingleObject(self.process, 2000) == win.WAIT_TIMEOUT) {
            _ = win.TerminateProcess(self.process, 1);
        }
    }

    pub fn finishClose(self: *Pty) void {
        _ = win.CloseHandle(self.process);
        self.conpty.unload();
    }
};

fn symbol(comptime T: type, module: win.HMODULE, name: [*:0]const u8) ?T {
    const address = win.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}

fn missingExport() error{ConptyExportNotFound} {
    log.err("bundled conpty.dll does not provide the required ConPTY API", .{});
    return error.ConptyExportNotFound;
}

fn windowsError() anyerror {
    return switch (win.GetLastError()) {
        win.ERROR_FILE_NOT_FOUND => error.ExecutableNotFound,
        win.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.WindowsApiFailure,
    };
}

fn resolveWorkingDirectory(configured: []const u8, user_profile: []const u8) []const u8 {
    return if (configured.len > 0) configured else user_profile;
}

test "empty working directory defaults to the user profile" {
    try std.testing.expectEqualStrings("C:\\Users\\test", resolveWorkingDirectory("", "C:\\Users\\test"));
    try std.testing.expectEqualStrings("C:\\work", resolveWorkingDirectory("C:\\work", "C:\\Users\\test"));
    try std.testing.expectEqualStrings("", resolveWorkingDirectory("", ""));
}
