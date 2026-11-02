import SwiftUI

// MARK: - 在线歌单（对标 any-listen 歌单页：源/排序/标签 → 歌单卡片 → 详情就地切换）
// 数据经 SonglistStore → any-listen 解析层；歌曲行复用 SongRow / PlayAllButton / CoverThumb。

struct SonglistBrowseView: View {
  @Environment(SonglistStore.self) private var store
  @Environment(PlayerStore.self) private var player
  @Binding var sel: SideItem

  var body: some View {
    browse
  }

  private var browse: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          header
          filterBar
          content
        }
        .padding(Theme.spaceLG)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .task { await store.loadIfNeeded() }
  }

  // MARK: 标题 + 来源

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("歌单")
        .font(Theme.display())
        .foregroundStyle(Theme.text)
      sourceMenu
      Spacer()
      if store.error != nil, store.lists.isEmpty {
        Text("加载失败")
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
      }
    }
  }

  @State private var sourceMenuHovered = false

  private var sourceMenu: some View {
    Menu {
      ForEach(SonglistStore.browsableSources, id: \.rawValue) { src in
        Button {
          Task { await store.switchSource(src.rawValue) }
        } label: {
          HStack(spacing: 6) {
            Text(SourceRegistry.capability(id: src.rawValue)?.displayName ?? src.rawValue)
            if store.sourceId == src.rawValue {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(store.sourceName)
          .font(Theme.caption())
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .medium))
      }
      .foregroundStyle(sourceMenuHovered ? Theme.text : Theme.text2)
      .contentShape(Rectangle())
      .onHover { sourceMenuHovered = $0 }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("切换歌单来源")
    .accessibilityLabel("歌单来源：\(store.sourceName)")
  }

  // MARK: 排序 + 标签

  private var filterBar: some View {
    HStack(spacing: 8) {
      ForEach(store.sorts, id: \.id) { sort in
        let selected = store.selectedSortId == sort.id
        Button {
          Task { await store.selectSort(sort.id) }
        } label: {
          HStack(spacing: 4) {
            if selected {
              Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            }
            Text(sort.name)
          }
          .font(Theme.caption(.semibold))
          .foregroundStyle(selected ? Theme.accent : Theme.text2)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
              .fill(selected ? Theme.navHover : Theme.card)
          )
        }
        .buttonStyle(.plain)
        .help("按\(sort.name)排序")
        .accessibilityLabel("排序：\(sort.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }

      allTagsMenu

      Spacer()

      if store.loading {
        ProgressView()
          .controlSize(.small)
          .help("加载中")
      }
    }
  }

  /// 全部分类菜单（分组展示；当前标签打勾）
  private var allTagsMenu: some View {
    Menu {
      Button {
        Task { await store.selectTag("") }
      } label: {
        HStack(spacing: 6) {
          Text("全部")
          if store.selectedTagId.isEmpty { Image(systemName: "checkmark") }
        }
      }
      ForEach(store.tagGroups, id: \.name) { group in
        Menu(group.name) {
          ForEach(group.list, id: \.id) { tag in
            Button {
              Task { await store.selectTag(tag.id) }
            } label: {
              HStack(spacing: 6) {
                Text(tag.name)
                if store.selectedTagId == tag.id { Image(systemName: "checkmark") }
              }
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 10, weight: .medium))
        Text(currentTagName)
          .font(Theme.caption(.semibold))
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .medium))
      }
      .foregroundStyle(store.selectedTagId.isEmpty ? Theme.text2 : Theme.accent)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
          .fill(Theme.card)
      )
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("选择歌单分类")
    .accessibilityLabel("分类：\(currentTagName)")
  }

  private var currentTagName: String {
    if store.selectedTagId.isEmpty { return "全部分类" }
    return store.tags.first(where: { $0.id == store.selectedTagId })?.name
      ?? store.tagGroups.flatMap(\.list).first(where: { $0.id == store.selectedTagId })?.name
      ?? store.selectedTagId
  }

  // MARK: 内容（网格 / 加载 / 空）

  @ViewBuilder private var content: some View {
    if store.loading && store.lists.isEmpty {
      HStack {
        Spacer()
        ProgressView()
          .padding(.vertical, 48)
        Spacer()
      }
    } else if store.lists.isEmpty {
      EmptyStateView(
        title: store.error ?? "该来源暂无歌单",
        systemImage: "square.grid.2x2",
        description: store.error == nil ? "换个来源或分类试试" : "点击重试",
        action: store.error == nil ? nil : { Task { await store.reload() } }
      )
    } else {
      SonglistGrid(items: store.lists) { item in
        sel = .songlistDetail(item, source: store.sourceId)
      }
      .padding(.vertical, 2)

      loadMoreRow
    }
  }

  @ViewBuilder private var loadMoreRow: some View {
    let hasMore = store.total > 0 ? store.lists.count < store.total : !store.lists.isEmpty
    HStack {
      Spacer()
      if store.loadingMore {
        ProgressView()
          .controlSize(.small)
          .padding(.vertical, 14)
      } else if hasMore {
        Button("加载更多") {
          Task { await store.loadMore() }
        }
        .buttonStyle(.bordered)
        .tint(Theme.text2)
        .controlSize(.small)
        .padding(.vertical, 10)
        .help("加载更多歌单")
      }
      Spacer()
    }
  }
}

// MARK: - 歌单卡片网格（浏览页与搜索页共用）

struct SonglistGrid: View {
  var items: [ALSongListItem]
  var open: (ALSongListItem) -> Void

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)],
      spacing: 18
    ) {
      ForEach(items, id: \.id) { item in
        SonglistCard(item: item) { open(item) }
      }
    }
  }
}

/// 歌单卡片：封面 + 名称 + 播放/作者。悬停封面浮出播放键（点击进详情）。
struct SonglistCard: View {
  var item: ALSongListItem
  var open: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .bottomTrailing) {
          CoverThumb(url: item.img, size: 152, cornerRadius: Theme.radiusCard)
          if isHovered {
            Image(systemName: "play.circle.fill")
              .font(.system(size: 30))
              .foregroundStyle(Theme.accentHover)
              .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
              .transition(.scale(scale: 0.85).combined(with: .opacity))
          }
        }
        .frame(width: 152, height: 152)

        Text(item.name)
          .font(Theme.body(.semibold))
          .foregroundStyle(isHovered ? Theme.text : Theme.text.opacity(0.92))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(subtitle)
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel("歌单：\(item.name)")
    .accessibilityHint(subtitle)
  }

  private var subtitle: String {
    var parts: [String] = []
    if let c = item.playCount, !c.isEmpty { parts.append(c) }
    if let a = item.author, !a.isEmpty { parts.append(a) }
    if let t = item.total { parts.append("\(t)首") }
    return parts.isEmpty ? "歌单" : parts.joined(separator: " · ")
  }
}

// MARK: - 歌单详情（作为顶层导航的一级；对标榜单详情页：头图 + 播放全部 + 歌曲表）

struct SonglistDetailView: View {
  @Environment(SonglistStore.self) private var store
  @Environment(PlayerStore.self) private var player
  let item: ALSongListItem
  let source: String

  private var songs: [MusicInfo] { store.detailSongs }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        detailHeader(item)
        actionBar
        columnHeader
        listBody
      }
      .padding(Theme.spaceLG)
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .task(id: item.id) { await store.loadDetail(item, fromSource: source) }
  }

  private func detailHeader(_ item: ALSongListItem) -> some View {
    HStack(alignment: .center, spacing: 16) {
      CoverThumb(url: item.img, size: 96, cornerRadius: 8)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.name)
          .font(Theme.display())
          .foregroundStyle(Theme.text)
          .lineLimit(2)
        Text(headerMeta(item))
          .font(Theme.body())
          .foregroundStyle(Theme.text2)
          .lineLimit(2)
        if let desc = store.detailInfo?.desc, !desc.isEmpty {
          Text(desc)
            .font(Theme.bodySM())
            .foregroundStyle(Theme.text2.opacity(0.8))
            .lineLimit(2)
            .help(desc)
        }
      }

      Spacer()
    }
  }

  private func headerMeta(_ item: ALSongListItem) -> String {
    var parts = [store.detailSourceName]
    if let c = item.playCount, !c.isEmpty { parts.append("播放 \(c)") }
    if let a = item.author, !a.isEmpty { parts.append(a) }
    parts.append(store.detailTotal > 0 ? "共 \(store.detailTotal) 首" : "共 \(songs.count) 首")
    return parts.joined(separator: " · ")
  }

  private var actionBar: some View {
    HStack(spacing: 10) {
      Button {
        playAll()
      } label: {
        Label("播放全部", systemImage: "play.fill")
          .font(.system(size: 13, weight: .semibold))
          .padding(.horizontal, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(Theme.accent)
      .foregroundStyle(.black)
      .disabled(songs.isEmpty)
      .help("按顺序播放整个歌单")

      if store.detailLoading {
        ProgressView()
          .controlSize(.small)
          .help("加载歌曲中")
      }

      Spacer()

      if let err = store.detailError, songs.isEmpty {
        Text(err)
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
      }
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 12) {
      Text("#")
        .frame(width: 28, alignment: .leading)
      Color.clear.frame(width: 40, height: 12)
      Text("歌曲")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("专辑")
        .frame(width: 200, alignment: .leading)
      Image(systemName: "heart")
        .frame(width: 24)
      Text("时长")
        .frame(width: 44, alignment: .trailing)
      Color.clear.frame(width: 24, height: 12)
    }
    .font(Theme.caption())
    .foregroundStyle(Theme.text2)
    .padding(.horizontal, 20)
    .padding(.bottom, 6)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Theme.separator)
        .frame(height: 1)
    }
  }

  @ViewBuilder private var listBody: some View {
    if songs.isEmpty {
      HStack {
        Spacer()
        if store.detailLoading {
          ProgressView()
            .scaleEffect(1.2)
            .padding(.vertical, 36)
        } else {
          EmptyStateView(
            title: store.detailError ?? "歌单暂无歌曲",
            systemImage: "music.note.list",
            description: store.detailError == nil ? "" : "点击返回换个歌单"
          )
          .frame(maxWidth: 480)
        }
        Spacer()
      }
    } else {
      LazyVStack(spacing: 0) {
        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
          SongRow(song: song, queue: songs, showIndex: i + 1)
          if i < songs.count - 1 {
            Rectangle()
              .fill(Theme.separator)
              .padding(.leading, 76)
              .padding(.trailing, 12)
              .frame(height: 1)
          }
        }
      }
      .padding(8)
    }
  }

  private func playAll() {
    guard let first = songs.first else { return }
    player.play(first, in: songs)
  }
}
