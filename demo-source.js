/*
 * @name Demo 温控源（MVP联调用）
 * @description 最小可运行示例：kw 走固定直链，lyric/pic 回固定值
 * @author imusic
 * @homepage https://example.com
 * @version 1.0.0
 */
lx.on('request', async ({ source, action, info }) => {
  if (action === 'musicUrl') {
    // info: { type: '128k'|'320k'|'flac'|'flac24bit', musicInfo: {...} }
    // MVP演示：直接返回一个可播放的 mp3（忽略签名）
    return 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3'
  }
  if (action === 'lyric') {
    return { lyric: '[00:00.00]MVP演示歌词\n[00:05.00]自定义源已接管\n', tlyric: null, rlyric: null, lxlyric: null }
  }
  if (action === 'pic') {
    return 'https://picsum.photos/300'
  }
  throw new Error('unsupported action ' + action)
})

await lx.send('inited', {
  sources: {
    kw: { type: 'music', actions: ['musicUrl', 'lyric', 'pic'], qualitys: ['128k', '320k', 'flac', 'flac24bit'] },
    kg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
  }
})
