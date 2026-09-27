import 'dart:typed_data';

/// 二进制协议头（《工程结构》§9.6）。
///
/// 线格式（little-endian，共 16 字节）：
/// ```
/// offset  0  uint32  magic
/// offset  4  uint16  version
/// offset  6  uint16  type
/// offset  8  uint32  size
/// offset 12  uint32  flags
/// ```
class WbBinaryHeader {
  const WbBinaryHeader({
    required this.magic,
    required this.version,
    required this.type,
    required this.size,
    required this.flags,
  });

  final int magic;
  final int version;
  final int type;
  final int size;
  final int flags;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'magic': magic,
        'version': version,
        'type': type,
        'size': size,
        'flags': flags,
      };

  @override
  String toString() =>
      'WbBinaryHeader(magic=0x${magic.toRadixString(16)}, version=$version, '
      'type=$type, size=$size, flags=$flags)';
}

/// 二进制编解码（配合 C++ serialization 域的二进制格式）。
abstract final class WbBinaryCodec {
  /// 协议头字节数。
  static const int headerSize = 16;

  /// 默认魔数（"WB\0\0"，与 serialization 域约定）。
  static const int defaultMagic = 0x00004257;

  /// 编码协议头。
  static Uint8List encodeHeader({
    required int magic,
    required int version,
    required int type,
    required int size,
    required int flags,
  }) {
    final Uint8List out = Uint8List(headerSize);
    final ByteData view = ByteData.view(out.buffer);
    view.setUint32(0, magic, Endian.little);
    view.setUint16(4, version, Endian.little);
    view.setUint16(6, type, Endian.little);
    view.setUint32(8, size, Endian.little);
    view.setUint32(12, flags, Endian.little);
    return out;
  }

  /// 解析协议头；字节不足或魔数不匹配时抛出 [FormatException]。
  static WbBinaryHeader decodeHeader(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw const FormatException('binary header requires 16 bytes');
    }
    final ByteData view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final WbBinaryHeader header = WbBinaryHeader(
      magic: view.getUint32(0, Endian.little),
      version: view.getUint16(4, Endian.little),
      type: view.getUint16(6, Endian.little),
      size: view.getUint32(8, Endian.little),
      flags: view.getUint32(12, Endian.little),
    );
    if (header.magic != defaultMagic) {
      throw FormatException(
        'bad magic 0x${header.magic.toRadixString(16)} '
        '(expected 0x${defaultMagic.toRadixString(16)})',
      );
    }
    return header;
  }

  /// 组装 头 + 载荷 的完整消息。
  static Uint8List encodeFrame({
    required int type,
    required Uint8List payload,
    int version = 1,
    int flags = 0,
    int magic = defaultMagic,
  }) {
    final Uint8List out = Uint8List(headerSize + payload.length);
    out.setRange(
      0,
      headerSize,
      encodeHeader(
        magic: magic,
        version: version,
        type: type,
        size: payload.length,
        flags: flags,
      ),
    );
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  /// 拆分 头 + 载荷；载荷长度与 `size` 不一致时抛出 [FormatException]。
  static (WbBinaryHeader, Uint8List) decodeFrame(Uint8List bytes) {
    final WbBinaryHeader header = decodeHeader(bytes);
    final int end = headerSize + header.size;
    if (end > bytes.length) {
      throw const FormatException('payload shorter than declared size');
    }
    return (header, Uint8List.sublistView(bytes, headerSize, end));
  }
}
