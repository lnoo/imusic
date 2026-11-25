import Foundation

// MARK: - 主页榜单目录（源 -> 榜单两级展开的唯一真相源）
//
// 目录双层：静态目录（本文件，含分类文案与默认选中）+ 动态目录（SearchService.boardCatalog，
// 来自 any-listen topSongs 接口，带榜图，kg/tx 有数十张榜）。查询入口：
//   SearchService.boards(for:)  动态优先，空/失败回退静态（本文件全量目录）
//   SearchService.board(id:)    同上（详情页用）
// id 形如 "kw__16"（source__榜单key），与主页缓存 key 同构，动态目录完全兼容。
// 实际抓取统一走 any-listen 解析层（AnyListenResource.topSongsDetail → 各源实现）。
// 静态目录的 kw/kg/tx/wy 全量榜（id/name/pic）移植自 online-metadata 对应 topSongs.ts 的
// boardList；mg 的 9 榜静态目录仍留在 AnyListenMg.swift（不在本文件重复）。

struct HomeBoard: Identifiable, Hashable, Sendable {
  var id: String { "\(sourceId)__\(key)" }
  var sourceId: String
  var key: String
  var name: String
  var category: String // 推荐 / 飙升 / 新歌 / 风格 / 场景；动态目录未分类时为空
  var pic: String? // 榜单封面（静态目录已移植全量榜图；卡片无图时回退首歌封面）
}

enum HomeBoards {

  // MARK: - 各源全量静态榜目录（ALTopSongsItem：id/name/pic 原样对齐 online-metadata boardList）

  /// KW 全量静态榜目录（online-metadata kw/topSongs.ts boardList）：31 榜，id/name/pic 原样移植
  private static let kwStaticBoards: [ALTopSongsItem] = [
    .init(id: "340", name: "青少年专属飙升榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/8/8/1543919795640_.png"),
    .init(id: "93", name: "酷我飙升榜", pic: "http://img3.kwcdn.kuwo.cn/star/upload/8/8/1543919795640_.png"),
    .init(id: "17", name: "酷我新歌榜", pic: "http://img4.kwcdn.kuwo.cn/star/upload/9/9/1543919747769_.png"),
    .init(id: "16", name: "酷我热歌榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/2/2/1543919658018_.png"),
    .init(id: "158", name: "抖音热歌榜", pic: "http://img4.kwcdn.kuwo.cn/star/upload/6/6/1554970547302_.png"),
    .init(id: "145", name: "会员畅听榜", pic: "http://img3.kwcdn.kuwo.cn/star/upload/1/1/1554695862673_.png"),
    .init(id: "176", name: "DJ嗨歌榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/9/9/1543805792217_.png"),
    .init(id: "69", name: "儿童歌曲榜", pic: "https://kwimg1.kuwo.cn/star/upload/83/45/1708661051345_.jpg"),
    .init(id: "344", name: "儿童故事榜", pic: "https://kwimg2.kuwo.cn/star/upload/64/29/1708661051623_.jpg"),
    .init(id: "284", name: "酷我热评榜", pic: "http://img3.kwcdn.kuwo.cn/star/upload/11/11/1576751304219_.png"),
    .init(id: "278", name: "古风音乐榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/12/12/1600079704156_.png"),
    .init(id: "264", name: "Vlog音乐榜", pic: "https://kwimg4.kuwo.cn/star/upload/48/48/1693479025902_.png"),
    .init(id: "242", name: "酷我电音榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/1/1/1588145907409_.png"),
    .init(id: "187", name: "流行趋势榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/13/13/1562810920205_.png"),
    .init(id: "204", name: "现场音乐榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/13/13/1567493121245_.png"),
    .init(id: "185", name: "最强翻唱榜", pic: "http://img3.kwcdn.kuwo.cn/star/upload/15/15/1558696739359_.png"),
    .init(id: "26", name: "经典怀旧榜", pic: "https://kwimg4.kuwo.cn/star/upload/71/0/1693479018896_.png"),
    .init(id: "104", name: "酷我华语榜", pic: "https://kwimg2.kuwo.cn/star/upload/89/89/1693479025943_.png"),
    .init(id: "182", name: "酷我粤语榜", pic: "https://kwimg2.kuwo.cn/star/upload/7/9/1693479026059_.png"),
    .init(id: "22", name: "酷我欧美榜", pic: "https://kwimg1.kuwo.cn/star/upload/93/93/1693479025947_.png"),
    .init(id: "184", name: "酷我韩语榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/5/5/1558696815381_.png"),
    .init(id: "183", name: "酷我日语榜", pic: "http://img4.kwcdn.kuwo.cn/star/upload/8/8/1558695640280_.png"),
    .init(id: "153", name: "网红新歌榜", pic: "https://kwimg4.kuwo.cn/star/upload/22/23/1693479025975_.png"),
    .init(id: "64", name: "影视金曲榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/9/9/1549010297209_.png"),
    .init(id: "151", name: "腾讯音乐人原创榜", pic: "https://kwimg4.kuwo.cn/star/upload/4/19/1693480696087_.png"),
    .init(id: "12", name: "Billboard榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/7/7/1543920767111_.png"),
    .init(id: "180", name: "beatport电音榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/0/0/1548990226481_.png"),
    .init(id: "13", name: "英国UK榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/4/4/1543920895540_.png"),
    .init(id: "164", name: "百大DJ榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/7/7/1543921876743_.png"),
    .init(id: "246", name: "YouTube音乐排行榜", pic: "http://img2.kwcdn.kuwo.cn/star/upload/14/14/1569378463582_.png"),
    .init(id: "15", name: "日本公信榜", pic: "http://img1.kwcdn.kuwo.cn/star/upload/11/11/1543921161339_.png"),
  ]

  /// KG 全量静态榜目录（online-metadata kg/topSongs.ts boardList）：55 榜，id/name/pic 原样移植
  private static let kgStaticBoards: [ALTopSongsItem] = [
    .init(id: "8888", name: "TOP500", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219164209670219.png"),
    .init(id: "85897", name: "国潮音乐榜", pic: "http://imge.kugou.com/mcommon/500/20241120/20241120202644296668.jpg"),
    .init(id: "100530", name: "视频号热歌酷狗榜", pic: "http://imge.kugou.com/mcommon/500/20251202/20251202193636899095.jpg"),
    .init(id: "51341", name: "民谣榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184719475668.jpg"),
    .init(id: "59900", name: "纯音乐榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185324343605.jpg"),
    .init(id: "33160", name: "电音榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184628349205.jpg"),
    .init(id: "82831", name: "网络热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219195626644029.png"),
    .init(id: "6666", name: "飙升榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219193628550054.png"),
    .init(id: "52144", name: "抖音热歌酷狗榜", pic: "http://imge.kugou.com/mcommon/500/20250725/20250725182524501565.png"),
    .init(id: "59896", name: "摇滚榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184944114279.jpg"),
    .init(id: "24971", name: "DJ热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219194419154116.png"),
    .init(id: "80025", name: "国乐榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184535924138.png"),
    .init(id: "85432", name: "百万收藏榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219171042182683.png"),
    .init(id: "52767", name: "快手热歌酷狗榜", pic: "http://imge.kugou.com/mcommon/500/20250725/20250725183206991263.png"),
    .init(id: "74534", name: "新歌榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219200509300768.png"),
    .init(id: "84235", name: "名品堂", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219195054422404.png"),
    .init(id: "31308", name: "内地榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192146592398.png"),
    .init(id: "33165", name: "粤语金曲榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219200119140556.png"),
    .init(id: "31310", name: "欧美榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192454699571.jpg"),
    .init(id: "51340", name: "伤感榜", pic: "http://imge.kugou.com/mcommon/500/20241219/20241219195213930623.png"),
    .init(id: "31311", name: "韩国榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192536531946.jpg"),
    .init(id: "31312", name: "日本榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192703831514.jpg"),
    .init(id: "31313", name: "香港地区榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192249298044.jpg"),
    .init(id: "42807", name: "JOOX香港热歌榜", pic: "http://imge.kugou.com/mcommon/500/20250609/20250609104556453665.jpg"),
    .init(id: "49225", name: "80后热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185822886829.jpg"),
    .init(id: "54848", name: "台湾地区榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211192349409526.jpg"),
    .init(id: "59895", name: "R&B榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184856929448.jpg"),
    .init(id: "44412", name: "说唱先锋榜", pic: "http://imge.kugou.com/mcommon/500/20240801/20240801174246809486.jpg"),
    .init(id: "49223", name: "90后热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185910253287.jpg"),
    .init(id: "42808", name: "KKBOX风云榜", pic: "http://imge.kugou.com/mcommon/500/20250605/20250605114541276767.jpg"),
    .init(id: "49224", name: "00后热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185955370846.jpg"),
    .init(id: "33162", name: "ACG新歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211184809101184.jpg"),
    .init(id: "35811", name: "会员热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211190815330214.jpg"),
    .init(id: "33166", name: "欧美金曲榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211190352819248.jpg"),
    .init(id: "33163", name: "影视金曲榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211190457598263.jpg"),
    .init(id: "59897", name: "爵士榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185038580940.jpg"),
    .init(id: "59898", name: "乡村音乐榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185123607801.jpg"),
    .init(id: "65234", name: "儿歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211191500485663.png"),
    .init(id: "60170", name: "闽南语榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211191332657103.jpg"),
    .init(id: "46910", name: "综艺新歌榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211191122925263.jpg"),
    .init(id: "30972", name: "酷狗音乐人原创榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211191231362267.jpg"),
    .init(id: "37361", name: "酷狗识曲榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211190930749712.jpg"),
    .init(id: "59899", name: "古典榜", pic: "http://imge.kugou.com/mcommon/500/20241211/20241211185545620318.jpg"),
    .init(id: "4681", name: "美国BillBoard榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129191451959672.jpg"),
    .init(id: "108332", name: "粤剧榜", pic: "http://imge.kugou.com/mcommon/500/20260318/20260318165457262501.jpg"),
    .init(id: "25028", name: "Beatport电子舞曲榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129191254713903.jpg"),
    .init(id: "108333", name: "京剧榜", pic: "http://imge.kugou.com/mcommon/500/20260318/20260318165621528435.jpg"),
    .init(id: "4680", name: "英国单曲榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129184843867507.jpg"),
    .init(id: "108335", name: "南音榜", pic: "http://imge.kugou.com/mcommon/500/20260318/20260318165732662096.jpg"),
    .init(id: "38623", name: "韩国Melon音乐榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129185007675569.jpg"),
    .init(id: "4673", name: "日本公信榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129190753306040.jpg"),
    .init(id: "46868", name: "日本SS榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129190920828981.jpg"),
    .init(id: "36107", name: "小语种热歌榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129184735526204.jpg"),
    .init(id: "60171", name: "越南语榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129184925598181.jpg"),
    .init(id: "60172", name: "泰语榜", pic: "http://imge.kugou.com/mcommon/500/20241129/20241129191037702382.jpg"),
  ]

  /// TX 全量静态榜目录（online-metadata tx/topSongs.ts boardList）：24 榜，id/name/pic 原样移植
  private static let txStaticBoards: [ALTopSongsItem] = [
    .init(id: "4", name: "流行指数榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001qdESL0Utojf.jpg"),
    .init(id: "26", name: "热歌榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002Sayej2GqCJH.jpg"),
    .init(id: "78", name: "国乐榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002iwP0g3FpEfy.jpg"),
    .init(id: "27", name: "新歌榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000000cPzvb0QoYOJ.jpg"),
    .init(id: "62", name: "飙升榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002qJVCm3Ooro8.jpg"),
    .init(id: "58", name: "说唱榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001JVH724BvKc2.jpg"),
    .init(id: "57", name: "电音榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000003jJbYt0SxaHf.jpg"),
    .init(id: "28", name: "网络歌曲榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002yBBlS3kfK5X.jpg"),
    .init(id: "5", name: "内地榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M0000017ztgy40tyJI.jpg"),
    .init(id: "3", name: "欧美榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000003AifhE09cZ2R.jpg"),
    .init(id: "59", name: "香港地区榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000003eD1GJ0ALk5X.jpg"),
    .init(id: "16", name: "韩国榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002XZzBK2MSSU8.jpg"),
    .init(id: "60", name: "抖音热歌榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001hgsNv0QfAXv.jpg"),
    .init(id: "29", name: "影视金曲榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002ga0xH0XStwr.jpg"),
    .init(id: "17", name: "日本榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M0000031EFNo1HbDqq.jpg"),
    .init(id: "36", name: "K歌金曲榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M0000012uqZu0dhyMv.jpg"),
    .init(id: "61", name: "台湾地区榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001w6CKZ3eRVAa.jpg"),
    .init(id: "63", name: "DJ舞曲榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002Nffh50T30L0.jpg"),
    .init(id: "64", name: "综艺新歌榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000002YaQ6b207Fl1.jpg"),
    .init(id: "65", name: "国风热歌榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001QsCFf3pvEyg.jpg"),
    .init(id: "67", name: "听歌识曲榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000000xxHg32YGjMI.jpg"),
    .init(id: "72", name: "动漫音乐榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000000yKnVs4Bxbik.jpg"),
    .init(id: "73", name: "游戏音乐榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001xs5992hUvcs.jpg"),
    .init(id: "75", name: "有声榜", pic: "http://y.gtimg.cn/music/photo_new/T003R300x300M000001M59IU1bvwY1.jpg"),
  ]

  /// WY 全量静态榜目录（online-metadata wy/topSongs.ts boardList）：62 榜，id/name/pic 原样移植
  private static let wyStaticBoards: [ALTopSongsItem] = [
    .init(id: "19723756", name: "飙升榜", pic: "https://p1.music.126.net/rIi7Qzy2i2Y_1QD7cd0MYA==/109951170048506929.jpg"),
    .init(id: "3779629", name: "新歌榜", pic: "https://p1.music.126.net/5guhqPBTcIrrhLBotgaT6w==/109951170048511751.jpg"),
    .init(id: "2884035", name: "原创榜", pic: "https://p1.music.126.net/BaP9nrocNTL3gGThysv4eQ==/109951170091896587.jpg"),
    .init(id: "3778678", name: "热歌榜", pic: "https://p1.music.126.net/0SUEG8yDACfx0Bw2MYFv4Q==/109951170048519512.jpg"),
    .init(id: "991319590", name: "网易云中文说唱榜", pic: "https://p1.music.126.net/GgHbgDfGXHpE2YTchU7IvA==/109951171510498108.jpg"),
    .init(id: "71384707", name: "网易云古典榜", pic: "https://p1.music.126.net/urByD_AmfBDBrs7fA9-O8A==/109951167976973225.jpg"),
    .init(id: "1978921795", name: "网易云电音榜", pic: "https://p1.music.126.net/hXGObvXfsGtFjFvRhOYAkA==/109951170091888741.jpg"),
    .init(id: "14028249541", name: "网易云全球说唱榜", pic: "https://p1.music.126.net/0hhFjP6WyIjHYDXKW5E7BA==/109951171535150782.jpg"),
    .init(id: "13372522766", name: "潮流风向榜", pic: "https://p1.music.126.net/dIKA5e7jCncz2Br1Toxgaw==/109951170621574552.jpg"),
    .init(id: "12911403728", name: "音乐合伙人推荐榜", pic: "https://p1.music.126.net/s6ITpmGjKbyDpi7DPkqd2w==/109951170187827373.jpg"),
    .init(id: "12911589513", name: "音乐合伙人热歌榜", pic: "https://p1.music.126.net/RgYxQmB-ZUjkMRo2N1jWnQ==/109951170187823494.jpg"),
    .init(id: "12911619970", name: "音乐合伙人留名榜", pic: "https://p1.music.126.net/aJJzGIxhkVaD7dX0XBNUnw==/109951170187831145.jpg"),
    .init(id: "12911379734", name: "音乐合伙人高分新歌榜", pic: "https://p1.music.126.net/bfk15bvanhdPFU7yjPFgWA==/109951170187832038.jpg"),
    .init(id: "12768855486", name: "音乐合伙人高分榜", pic: "https://p1.music.126.net/fPP5T0Z8Ac15qNvRTcHa6g==/109951170074028970.jpg"),
    .init(id: "5453912201", name: "黑胶VIP爱听榜", pic: "https://p1.music.126.net/qo6-o9n5AhMjNyejev38-A==/109951169743111905.jpg"),
    .init(id: "71385702", name: "网易云ACG榜", pic: "https://p1.music.126.net/na1kEeCS1iZEkzOrs9r_9g==/109951167976973667.jpg"),
    .init(id: "745956260", name: "网易云韩语榜", pic: "https://p1.music.126.net/5oN9YaFznwNGXkmi8i2Ytw==/109951167430864741.jpg"),
    .init(id: "180106", name: "UK排行榜周榜", pic: "https://p1.music.126.net/fhAqiflLy3eU-ldmBQByrg==/109951165613082765.jpg"),
    .init(id: "60198", name: "美国Billboard榜", pic: "https://p1.music.126.net/rwRsVIJHQ68gglhA6TNEYA==/109951165611413732.jpg"),
    .init(id: "3812895", name: "Beatport全球电子舞曲榜", pic: "https://p1.music.126.net/oT-RHuPBJiD7WMoU7WG5Rw==/109951166093489621.jpg"),
    .init(id: "21845217", name: "KTV唛榜", pic: "https://p1.music.126.net/5wDP78s43ydVTKt62C8OjQ==/109951165613100063.jpg"),
    .init(id: "60131", name: "日本Oricon榜", pic: "https://p1.music.126.net/aXUPgImt8hhf4cMUZEjP4g==/109951165611417794.jpg"),
    .init(id: "2809513713", name: "网易云欧美热歌榜", pic: "https://p1.music.126.net/70_EO_Dc7NT_hhfvsapzcQ==/109951167430862162.jpg"),
    .init(id: "2809577409", name: "网易云欧美新歌榜", pic: "https://p1.music.126.net/0lPWpI9Ejn1OiW2LSbg-qw==/109951167430863224.jpg"),
    .init(id: "27135204", name: "法国 NRJ Vos Hits 周榜", pic: "https://p2.music.126.net/-fyzrPWd06FfWl_0JDAxMQ==/109951165613108584.jpg"),
    .init(id: "3001835560", name: "网易云ACG动画榜", pic: "https://p2.music.126.net/SkGlKQ6acixthb77VlD9eQ==/109951164432300406.jpg"),
    .init(id: "3001795926", name: "网易云ACG游戏榜", pic: "https://p2.music.126.net/hivOOHMwEmnn9s_6rgZwEQ==/109951164432303700.jpg"),
    .init(id: "3001890046", name: "网易云ACG VOCALOID榜", pic: "https://p2.music.126.net/Ag7RyRCYiINcd9EtRXf6xA==/109951164432303690.jpg"),
    .init(id: "5059644681", name: "网易云日语榜", pic: "https://p2.music.126.net/YFBFNI2F-4BveUpv6FKFuw==/109951167430864069.jpg"),
    .init(id: "5059633707", name: "网易云摇滚榜", pic: "https://p2.music.126.net/LjkX2hktgFD1NXc3W6w0sA==/109951170048522513.jpg"),
    .init(id: "5059642708", name: "网易云国风榜", pic: "https://p2.music.126.net/kTJC5OBhg8I477X_ZmXyDQ==/109951168539740982.jpg"),
    .init(id: "5338990334", name: "潜力爆款榜", pic: "https://p2.music.126.net/Mi4QPklg1mtbWAfq74tEqQ==/109951165498334721.jpg"),
    .init(id: "5059661515", name: "网易云民谣榜", pic: "https://p2.music.126.net/Xe9qLTAqtBAWX_hPgFHMyw==/109951170048510929.jpg"),
    .init(id: "6688069460", name: "听歌识曲榜", pic: "https://p2.music.126.net/wJVUAiUuykKk7yGbQxDBug==/109951167430857712.jpg"),
    .init(id: "6723173524", name: "网络热歌榜", pic: "https://p2.music.126.net/_kSxOPqQ5J5etC5DKTFwNA==/109951170048519530.jpg"),
    .init(id: "6732051320", name: "俄语榜", pic: "https://p2.music.126.net/HbJ0BK5doY4I4pEMY6-FQw==/109951167430852698.jpg"),
    .init(id: "6732014811", name: "越南语榜", pic: "https://p2.music.126.net/N-Y5maLGWgrowt3TE6RtSg==/109951167430857045.jpg"),
    .init(id: "6886768100", name: "中文慢摇DJ榜", pic: "https://p2.music.126.net/w_01BfDU012ojxnzLO6tYw==/109951167977358686.jpg"),
    .init(id: "6939992364", name: "俄罗斯top hit流行音乐榜", pic: "https://p2.music.126.net/KLVO8PxVZzOoLdWQQNyprA==/109951166327316568.jpg"),
    .init(id: "7095271308", name: "泰语榜", pic: "https://p2.music.126.net/4W0WBHBgwYlYfRniuyL47A==/109951167430843284.jpg"),
    .init(id: "7356827205", name: "BEAT排行榜", pic: "https://p2.music.126.net/yhzlQJCJ9NcT4MvJBG_HgQ==/109951167977014958.jpg"),
    .init(id: "7325478166", name: "星云榜VOL.31 翁杰新专来袭，愿我们拥有广阔的天地！", pic: "https://p2.music.126.net/m9HWYdcz9xH-7SSito3-3A==/109951172864859483.jpg"),
    .init(id: "7603212484", name: "LOOK直播歌曲榜", pic: "https://p2.music.126.net/u-RQC-LyY0aoeseRumJ14A==/109951167977730469.jpg"),
    .init(id: "7775163417", name: "赏音榜", pic: "https://p2.music.126.net/m9hQzC-d5wefBipedNPaHg==/109951168178601971.jpg"),
    .init(id: "7785123708", name: "黑胶VIP新歌榜", pic: "https://p2.music.126.net/vjitpkT9nXBCth6tvdDMWg==/109951169743115266.jpg"),
    .init(id: "7785066739", name: "黑胶VIP热歌榜", pic: "https://p2.music.126.net/Ay3mLgQ9weG_c8JjYrD-Bw==/109951169743106495.jpg"),
    .init(id: "7785091694", name: "黑胶VIP爱搜榜", pic: "https://p2.music.126.net/R7DtZqNraesnsiaIKvzTHA==/109951169743112799.jpg"),
    .init(id: "8246775932", name: "实时热度榜", pic: "https://p2.music.126.net/U7ZbdpWzRdmZVr6Khn_4ag==/109951168673982478.jpg"),
    .init(id: "8537588450", name: "喜力®星电音派对潮音榜", pic: "https://p2.music.126.net/HVu2hGYvzN5XBuvFc_4Bgg==/109951168730309120.jpg"),
    .init(id: "8661209031", name: "乐夏榜", pic: "https://p2.music.126.net/RlStCmE97y0xYFk7rS3Zww==/109951168864907822.jpg"),
    .init(id: "8703179781", name: "特斯拉车友爱听榜", pic: "https://p2.music.126.net/UL8dhobSa3TR6Wd1JmWe_g==/109951168924385363.jpg"),
    .init(id: "8703052295", name: "理想车友爱听榜", pic: "https://p2.music.126.net/U--PWdWupY1ER5cVSjr1jQ==/109951168928365496.jpg"),
    .init(id: "8702582160", name: "比亚迪车友爱听榜", pic: "https://p2.music.126.net/S1OG-OLTaofa3HfrHW48kA==/109951168924393585.jpg"),
    .init(id: "8703220480", name: "蔚来车友爱听榜", pic: "https://p2.music.126.net/r9kBQNsOro1EAB82Ol51WQ==/109951168924380971.jpg"),
    .init(id: "8702982391", name: "极氪车友爱听榜", pic: "https://p2.music.126.net/Cu0RXoKewSPM9Gyc7Cp8jw==/109951168924391596.jpg"),
    .init(id: "8532443277", name: "蛋仔派对听歌榜", pic: "https://p2.music.126.net/TMb0be5QLMZKOFeuOKT4tg==/109951168717283910.jpg"),
    .init(id: "9651277674", name: "AI歌曲榜", pic: "https://p2.music.126.net/M0m6GeZ1Y8Osz9jqxaW8Wg==/109951169462048035.jpg"),
    .init(id: "10131772880", name: "昊铂车友爱听榜", pic: "https://p2.music.126.net/EL7H4rkKejZY7Uv54EFNXg==/109951169655010112.jpg"),
    .init(id: "10162841534", name: "埃安车友爱听榜", pic: "https://p2.music.126.net/FcP1U6Bck0wPKqd0XgBwSQ==/109951169679731241.jpg"),
    .init(id: "12225155968", name: "欧美R&B榜", pic: "https://p2.music.126.net/0E6MzYzyA5uvQ4CSoIG2mw==/109951169739660034.jpg"),
    .init(id: "12344472377", name: "黑胶VIP限免榜", pic: "https://p2.music.126.net/WXCSf4ZNcDCdOTY5ixm3Bg==/109951169809318325.jpg"),
    .init(id: "12717025277", name: "吉利车友爱听榜", pic: "https://p2.music.126.net/XVmZb3JSyrwMgqu9WVz61A==/109951170037568570.jpg"),
  ]

  /// 静态榜目录（全量兜底）。mg 沿用 AnyListenMg 内部静态目录，这里返回空。
  /// 供动态目录失败/为空时的兜底与对齐校验使用。
  static func staticBoards(for source: MusicSource) -> [ALTopSongsItem] {
    switch source {
    case .kw: return kwStaticBoards
    case .kg: return kgStaticBoards
    case .tx: return txStaticBoards
    case .wy: return wyStaticBoards
    default: return []
    }
  }

  /// 既有策展目录：保留原分类文案与默认选中顺序；新移植的全量榜追加在后面（未分类）。
  private static let curated: [(sourceId: String, key: String, name: String, category: String)] = [
    ("kw", "16", "热歌榜", "推荐"),
    ("kw", "93", "飙升榜", "飙升"),
    ("kw", "17", "新歌榜", "新歌"),
    ("kw", "158", "抖音热歌榜", "场景"),
    ("kw", "104", "华语榜", "风格"),
    ("kw", "182", "粤语榜", "风格"),
    ("kw", "22", "欧美榜", "风格"),
    ("kw", "183", "日语榜", "风格"),
    ("kw", "184", "韩语榜", "风格"),
    ("kw", "278", "古风音乐榜", "风格"),
    ("kw", "242", "电音榜", "风格"),
    ("kw", "176", "DJ嗨歌榜", "风格"),
    ("kw", "64", "影视金曲榜", "场景"),
    ("kw", "26", "经典怀旧榜", "场景"),
    ("kg", "8888", "TOP500", "推荐"),
    ("kg", "6666", "飙升榜", "飙升"),
    ("tx", "26", "热歌榜", "推荐"),
    ("tx", "4", "流行指数榜", "推荐"),
    ("tx", "27", "新歌榜", "新歌"),
    ("tx", "28", "网络歌曲榜", "场景"),
    ("wy", "3778678", "热歌榜", "推荐"),
    ("wy", "19723756", "飙升榜", "飙升"),
    ("wy", "3779629", "新歌榜", "新歌"),
    ("wy", "10520166", "电音榜", "风格"),
    ("mg", "27186466", "尖叫热歌榜", "推荐"),
  ]

  static let all: [HomeBoard] = {
    var result: [HomeBoard] = []
    var seen = Set<String>()
    // 1) 策展榜优先（默认选中 "热歌榜" 保持在各源首位），并补上静态目录封面
    for c in Self.curated {
      let src = MusicSource(rawValue: c.sourceId)
      let pic = src.flatMap { Self.staticBoards(for: $0).first(where: { $0.id == c.key })?.pic }
      let board = HomeBoard(sourceId: c.sourceId, key: c.key, name: c.name,
                            category: c.category, pic: pic)
      result.append(board)
      seen.insert(board.id)
    }
    // 2) 全量静态目录补齐其余榜（mg 保持原状，仅策展的 1 榜）
    for srcId in ["kw", "kg", "tx", "wy"] {
      guard let src = MusicSource(rawValue: srcId) else { continue }
      for item in Self.staticBoards(for: src) {
        let id = "\(srcId)__\(item.id)"
        if seen.contains(id) { continue }
        seen.insert(id)
        result.append(HomeBoard(sourceId: srcId, key: item.id, name: item.name,
                                category: "", pic: item.pic))
      }
    }
    return result
  }()

  static let defaultSourceId = "kw"
  static let defaultBoardId = "kw__16"

  /// 有榜单的源（主页顶部资源切换器的顺序，跟随 SourceRegistry 排序）
  static var sources: [SourceCapability] {
    let ids = Set(all.map(\.sourceId))
    return SourceRegistry.withBoard.filter { ids.contains($0.id) }
  }

  static func boards(for sourceId: String) -> [HomeBoard] {
    all.filter { $0.sourceId == sourceId }
  }

  static func board(id: String) -> HomeBoard? {
    all.first { $0.id == id }
  }

  /// 动态目录条目 → HomeBoard：同名 key 继承静态分类，其余为未分类
  static func dynamicBoard(sourceId: String, item: ALTopSongsItem) -> HomeBoard {
    HomeBoard(
      sourceId: sourceId, key: item.id, name: item.name,
      category: all.first(where: { $0.sourceId == sourceId && $0.key == item.id })?.category ?? "",
      pic: item.pic
    )
  }
}

/// 按目录抓取单榜：分发到 any-listen 解析层（topSongsDetail）
enum HomeBoardFetcher {
  static func fetch(_ board: HomeBoard, limit: Int = 10) async throws -> [MusicInfo] {
    guard let source = MusicSource(rawValue: board.sourceId) else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知榜单源 \(board.sourceId)"])
    }
    let r = try await AnyListenResource.topSongsDetail(source: source, id: board.key, limit: limit)
    return r.list
  }
}
