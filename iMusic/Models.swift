import Foundation

// MARK: - 对标原项目类型 (100% Swift 6 Sendable 完备)
// src/common/types/user_api.d.ts + music.d.ts + app_setting.d.ts (common.apiSource)

/// 音乐平台源，对标 LX.Source
enum MusicSource: String, CaseIterable, Codable, Hashable, Sendable {
  case kw, kg, tx, wy, mg, local
  /// 显示名唯一来源：SourceRegistry（加新源只改注册处）
  var displayName: String {
    let name = SourceRegistry.capability(id: rawValue)?.displayName ?? rawValue
    return "\(name) (\(rawValue))"
  }
}

/// 音质，对标 LX.Quality
enum MusicQuality: String, CaseIterable, Codable, Hashable, Sendable {
  case q128k = "128k"
  case q320k = "320k"
  case flac
  case flac24bit

  /// 高->低，用于降级选择（对标 getPlayQuality）
  static var highToLow: [MusicQuality] { [.flac24bit, .flac, .q320k, .q128k] }
}

enum UserApiAction: String, Codable, Hashable, Sendable {
  case musicUrl, lyric, pic
}

/// 自定义源声明的单个平台能力，对标 LX.UserApi.UserApiSourceInfo
struct UserApiSourceInfo: Codable, Hashable, Sendable {
  var type: String = "music" // 仅支持 "music"
  var actions: [UserApiAction]
  var qualitys: [MusicQuality]
}

/// 自定义源元信息（去 script 版），对标 LX.UserApi.UserApiInfo
/// NOTE: sources 在 JS inited 之前为 nil，inited 之后由宿主过滤填充
struct UserApiInfo: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var description: String
  var author: String
  var homepage: String
  var version: String
  var allowShowUpdateAlert: Bool
  var sources: [String: UserApiSourceInfo]? // key = MusicSource.rawValue（Codable 兼容）
}

/// 含 script 的完整版，对标 LX.UserApi.UserApiInfoFull
/// script 存储格式与原项目一致：`gz_` + base64(zlib.deflate(raw utf8))
/// 见 src/main/modules/userApi/utils.ts deflateScript/inflateScript
struct UserApiInfoFull: Codable, Sendable {
  var id: String
  var name: String
  var description: String
  var author: String
  var homepage: String
  var version: String
  var allowShowUpdateAlert: Bool
  var script: String
}

// MARK: - Music

struct MusicQualityType: Codable, Hashable, Sendable {
  var type: MusicQuality
  var size: String?
}

struct MusicInfo: Identifiable, Hashable, Codable, Sendable {
  var id: String { "\(source.rawValue)_\(songmid)" }
  var name: String
  var singer: String
  var source: MusicSource
  var songmid: String
  var albumName: String
  var interval: String?
  var qualitys: [MusicQualityType]
  var picUrl: String?
  /// 各源私有字段透传（对标 meta 变体）：kg{hash,albumAudioId} tx{strMediaMid}
  /// mg{copyrightId} + 通用 intervalSecs。供官站歌词/封面兜底使用。
  var extra: [String: String]?

  var availableQualitys: [MusicQuality] { qualitys.map(\.type) }
}

struct LyricInfo: Codable, Hashable, Sendable {
  var lyric: String
  var tlyric: String?
  var rlyric: String?
  var lxlyric: String?
}

struct UpdateAlert: Hashable, Sendable {
  var name: String
  var log: String
  var updateUrl: String?
}
