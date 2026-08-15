const r4os = @import("r4os");

const DATA: u16 = 0x1F0;
const ERROR: u16 = 0x1F1;
const SECTOR_COUNT: u16 = 0x1F2;
const LBA_LOW: u16 = 0x1F3;
const LBA_MID: u16 = 0x1F4;
const LBA_HIGH: u16 = 0x1F5;
const DRIVE_HEAD: u16 = 0x1F6;
const STATUS_COMMAND: u16 = 0x1F7;
const ALT_STATUS: u16 = 0x3F6;

const STATUS_ERR: u8 = 0x01;
const STATUS_DRQ: u8 = 0x08;
const STATUS_BSY: u8 = 0x80;

const CMD_IDENTIFY_DEVICE: u8 = 0xEC;
const CMD_READ_SECTORS: u8 = 0x20;
const CMD_WRITE_SECTORS: u8 = 0x30;
const CMD_CACHE_FLUSH: u8 = 0xE7;

const SECTOR_SIZE: usize = 512;
const MAX_TRANSFER_SECTORS: u16 = 8;
const MAX_LBA28: u64 = 0x0FFF_FFFF;

const DiskRuntime = extern struct {
    present: bool = false,
    usable: bool = false,
    registered: bool = false,
    drive_select: u8 = 0,
    slot: u8 = 0,
    sector_count: u64 = 0,
    last_error: u32 = 0,
    last_lba: u64 = 0,
    last_sectors: u32 = 0,
    failures: u64 = 0,
};

var driver_ctx: r4os.r4dev.DriverContext = undefined;
var disks = [_]DiskRuntime{
    .{ .drive_select = 0xE0, .slot = 0 },
    .{ .drive_select = 0xF0, .slot = 1 },
};
var backends: [disks.len]r4os.abi.StorageBackend = .{r4os.abi.StorageBackend{}} ** disks.len;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("atapio_init", "atapio_shutdown"));
}

export fn atapio_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    driver_ctx = r4os.r4dev.DriverContext.init(api);
    if (!driver_ctx.apiCompatible()) {
        driver_ctx.logError("ATAPIO.R4D driver api mismatch");
        return -3;
    }

    resetState();

    var registered: usize = 0;
    var index: usize = 0;
    while (index < disks.len) : (index += 1) {
        const disk = &disks[index];
        if (!probeDisk(disk)) {
            continue;
        }
        if (registerBlockDevice(disk, index)) {
            registered += 1;
        }
    }

    if (registered == 0) {
        driver_ctx.logWarn("ATAPIO.R4D no legacy IDE disk found; preload boundary only");
        return 0;
    }

    driver_ctx.logInfo("ATAPIO.R4D legacy storage backend ready");
    return 0;
}

export fn atapio_shutdown() callconv(.c) i32 {
    return 0;
}

fn resetState() void {
    disks = [_]DiskRuntime{
        .{ .drive_select = 0xE0, .slot = 0 },
        .{ .drive_select = 0xF0, .slot = 1 },
    };
    backends = .{r4os.abi.StorageBackend{}} ** disks.len;
}

fn probeDisk(disk: *DiskRuntime) bool {
    disk.present = false;
    disk.usable = false;
    disk.sector_count = 0;

    if (identifyDisk(disk)) {
        disk.present = true;
    }

    var sector: [SECTOR_SIZE]u8 = undefined;
    if (!readSectors(disk, 0, 1, sector[0..])) {
        return false;
    }

    disk.present = true;
    disk.usable = true;
    return true;
}

fn identifyDisk(disk: *DiskRuntime) bool {
    selectDrive(disk, 0);
    outb(SECTOR_COUNT, 0);
    outb(LBA_LOW, 0);
    outb(LBA_MID, 0);
    outb(LBA_HIGH, 0);
    outb(STATUS_COMMAND, CMD_IDENTIFY_DEVICE);

    const initial = inb(STATUS_COMMAND);
    if (initial == 0) return fail(disk, 10);
    if (!waitForData(disk)) return false;

    var words: [256]u16 = undefined;
    var index: usize = 0;
    while (index < words.len) : (index += 1) {
        words[index] = inw(DATA);
    }

    disk.sector_count = @as(u64, words[60]) | (@as(u64, words[61]) << 16);
    return true;
}

fn registerBlockDevice(disk: *DiskRuntime, slot: usize) bool {
    if (slot >= backends.len) return false;
    const backend = &backends[slot];
    backend.* = .{
        .flags = r4os.abi.storage_backend_flag_writable,
        .source = r4os.abi.storage_backend_source_preload,
        .bus = r4os.abi.storage_backend_bus_ata,
        .sector_size = SECTOR_SIZE,
        .max_sectors_per_request = MAX_TRANSFER_SECTORS,
        .queue_depth = 1,
        .timeout_ticks = 0,
        .sector_count = disk.sector_count,
        .context = disk,
        .read = storageRead,
        .write = storageWrite,
        .flush = storageFlush,
        .shutdown = storageShutdown,
        .status = storageStatus,
    };
    copyController(&backend.controller, "ATAPIO.R4D");
    const block_index = driver_ctx.registerStorageBackend(nameForDisk(slot), backend);
    if (block_index < 0) return fail(disk, 20);
    disk.registered = true;
    return true;
}

fn storageRead(ctx: ?*anyopaque, lba: u64, sectors: u32, out: [*]u8, len: u32) callconv(.c) i32 {
    const disk = diskFromContext(ctx) orelse return -1;
    if (sectors == 0 or sectors > MAX_TRANSFER_SECTORS) return -2;
    const sector_count: u16 = @intCast(sectors);
    const data = out[0..@intCast(len)];
    return if (readSectors(disk, lba, sector_count, data)) 0 else -3;
}

fn storageWrite(ctx: ?*anyopaque, lba: u64, sectors: u32, data_ptr: [*]const u8, len: u32) callconv(.c) i32 {
    const disk = diskFromContext(ctx) orelse return -1;
    if (sectors == 0 or sectors > MAX_TRANSFER_SECTORS) return -2;
    const sector_count: u16 = @intCast(sectors);
    const data = data_ptr[0..@intCast(len)];
    return if (writeSectors(disk, lba, sector_count, data)) 0 else -3;
}

fn storageFlush(ctx: ?*anyopaque) callconv(.c) i32 {
    const disk = diskFromContext(ctx) orelse return -1;
    return if (flushBlock(disk)) 0 else -2;
}

fn storageShutdown(ctx: ?*anyopaque) callconv(.c) i32 {
    _ = ctx;
    return 0;
}

fn storageStatus(ctx: ?*anyopaque, out: *r4os.abi.StorageBackendStatus) callconv(.c) i32 {
    const disk = diskFromContext(ctx) orelse return -1;
    out.* = .{
        .state = if (disk.usable) 1 else 0,
        .last_error = disk.last_error,
        .last_lba = disk.last_lba,
        .last_sectors = disk.last_sectors,
        .recoveries = 0,
        .recovery_failures = disk.failures,
    };
    return 0;
}

fn readSectors(disk: *DiskRuntime, start_lba: u64, sectors: u16, out: []u8) bool {
    const bytes = validateTransfer(disk, start_lba, sectors, out.len) orelse return false;
    _ = bytes;

    var i: u16 = 0;
    while (i < sectors) : (i += 1) {
        const lba = start_lba + i;
        const offset = @as(usize, i) * SECTOR_SIZE;
        if (!readOne(disk, lba, out[offset .. offset + SECTOR_SIZE])) return false;
    }
    return true;
}

fn readOne(disk: *DiskRuntime, lba: u64, out: []u8) bool {
    selectDrive(disk, lba);
    outb(SECTOR_COUNT, 1);
    outb(LBA_LOW, @truncate(lba));
    outb(LBA_MID, @truncate(lba >> 8));
    outb(LBA_HIGH, @truncate(lba >> 16));
    outb(STATUS_COMMAND, CMD_READ_SECTORS);

    if (!waitForData(disk)) return false;

    var i: usize = 0;
    while (i < SECTOR_SIZE) : (i += 2) {
        const word = inw(DATA);
        out[i] = @truncate(word);
        out[i + 1] = @truncate(word >> 8);
    }

    return true;
}

fn writeSectors(disk: *DiskRuntime, start_lba: u64, sectors: u16, data: []const u8) bool {
    const bytes = validateTransfer(disk, start_lba, sectors, data.len) orelse return false;
    _ = bytes;

    var i: u16 = 0;
    while (i < sectors) : (i += 1) {
        const lba = start_lba + i;
        const offset = @as(usize, i) * SECTOR_SIZE;
        if (!writeOne(disk, lba, data[offset .. offset + SECTOR_SIZE])) return false;
    }
    return flushBlock(disk);
}

fn writeOne(disk: *DiskRuntime, lba: u64, data: []const u8) bool {
    selectDrive(disk, lba);
    outb(SECTOR_COUNT, 1);
    outb(LBA_LOW, @truncate(lba));
    outb(LBA_MID, @truncate(lba >> 8));
    outb(LBA_HIGH, @truncate(lba >> 16));
    outb(STATUS_COMMAND, CMD_WRITE_SECTORS);

    if (!waitForData(disk)) return false;

    var i: usize = 0;
    while (i < SECTOR_SIZE) : (i += 2) {
        const word = @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8);
        outw(DATA, word);
    }

    return waitNotBusy(disk);
}

fn flushBlock(disk: *DiskRuntime) bool {
    selectDrive(disk, 0);
    outb(STATUS_COMMAND, CMD_CACHE_FLUSH);
    return waitNotBusy(disk);
}

fn validateTransfer(disk: *DiskRuntime, start_lba: u64, sectors: u16, buffer_len: usize) ?usize {
    if (sectors == 0 or sectors > MAX_TRANSFER_SECTORS) return failNull(disk, 30);
    if (start_lba > MAX_LBA28) return failNull(disk, 31);
    if (start_lba + sectors - 1 > MAX_LBA28) return failNull(disk, 32);
    const bytes = @as(usize, sectors) * SECTOR_SIZE;
    if (buffer_len < bytes) return failNull(disk, 33);
    if (disk.sector_count != 0) {
        if (start_lba >= disk.sector_count) return failNull(disk, 34);
        if (@as(u64, sectors) > disk.sector_count - start_lba) return failNull(disk, 35);
    }
    disk.last_lba = start_lba;
    disk.last_sectors = sectors;
    return bytes;
}

fn selectDrive(disk: *DiskRuntime, lba: u64) void {
    outb(DRIVE_HEAD, disk.drive_select | @as(u8, @truncate((lba >> 24) & 0x0F)));
    delay400ns();
}

fn waitForData(disk: *DiskRuntime) bool {
    var guard: u32 = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const status = inb(STATUS_COMMAND);
        if ((status & STATUS_ERR) != 0) {
            _ = inb(ERROR);
            return fail(disk, 40);
        }
        if ((status & STATUS_BSY) == 0 and (status & STATUS_DRQ) != 0) return true;
    }
    return fail(disk, 41);
}

fn waitNotBusy(disk: *DiskRuntime) bool {
    var guard: u32 = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const status = inb(STATUS_COMMAND);
        if ((status & STATUS_ERR) != 0) {
            _ = inb(ERROR);
            return fail(disk, 50);
        }
        if ((status & STATUS_BSY) == 0) return true;
    }
    return fail(disk, 51);
}

fn delay400ns() void {
    _ = inb(ALT_STATUS);
    _ = inb(ALT_STATUS);
    _ = inb(ALT_STATUS);
    _ = inb(ALT_STATUS);
}

fn fail(disk: *DiskRuntime, code: u32) bool {
    disk.last_error = code;
    disk.failures += 1;
    return false;
}

fn failNull(disk: *DiskRuntime, code: u32) ?usize {
    _ = fail(disk, code);
    return null;
}

fn diskFromContext(ctx: ?*anyopaque) ?*DiskRuntime {
    const ptr = ctx orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn nameForDisk(slot: usize) [*:0]const u8 {
    return switch (slot) {
        0 => "ata0",
        1 => "ata1",
        else => "ata?",
    };
}

fn copyController(out: *[32]u8, text: []const u8) void {
    @memset(out[0..], 0);
    const n = if (text.len < out.len) text.len else out.len - 1;
    if (n > 0) @memcpy(out[0..n], text[0..n]);
}

fn inb(port: u16) u8 {
    return driver_ctx.portInb(port);
}

fn outb(port: u16, value: u8) void {
    driver_ctx.portOutb(port, value);
}

fn inw(port: u16) u16 {
    return driver_ctx.portInw(port);
}

fn outw(port: u16, value: u16) void {
    driver_ctx.portOutw(port, value);
}
