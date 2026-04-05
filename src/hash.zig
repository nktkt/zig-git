const std = @import("std");

pub const Sha1 = std.crypto.hash.Sha1;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const SHA1_DIGEST_LENGTH = Sha1.digest_length; // 20
pub const SHA1_HEX_LENGTH = SHA1_DIGEST_LENGTH * 2; // 40
pub const SHA256_DIGEST_LENGTH = Sha256.digest_length; // 32
pub const SHA256_HEX_LENGTH = SHA256_DIGEST_LENGTH * 2; // 64

pub fn hexToBytes(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.InvalidHexLength;
    for (out, 0..) |*byte, i| {
        const hi: u8 = try hexDigit(hex[i * 2]);
        const lo: u8 = try hexDigit(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexChar,
    };
}

pub fn bytesToHex(bytes: []const u8, out: []u8) void {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = charset[byte >> 4];
        out[i * 2 + 1] = charset[byte & 0x0f];
    }
}


pub fn sha1Digest(data: []const u8) [SHA1_DIGEST_LENGTH]u8 {
    var hasher = Sha1.init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

pub fn sha1DigestHex(data: []const u8) [SHA1_HEX_LENGTH]u8 {
    const digest = sha1Digest(data);
    var hex: [SHA1_HEX_LENGTH]u8 = undefined;
    bytesToHex(&digest, &hex);
    return hex;
}

test "hex round-trip" {
    const hex = "deadbeef01234567890abcdef0123456789abcde";
    var bytes: [20]u8 = undefined;
    try hexToBytes(hex, &bytes);
    var out: [40]u8 = undefined;
    bytesToHex(&bytes, &out);
    try std.testing.expectEqualStrings(hex, &out);
}

test "sha1 known value" {
    const hex = sha1DigestHex("blob 0\x00");
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}
