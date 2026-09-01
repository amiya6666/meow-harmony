import { media } from '@kit.MediaKit';
import { avSession as AVSessionManager, AVCastPicker } from '@kit.AVSessionKit';
import { audio } from '@kit.AudioKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { bundleManager, wantAgent, ConfigurationConstant } from '@kit.AbilityKit';
import { curves, display, window } from '@kit.ArkUI';
import { BusinessError, pasteboard, request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import {
  Album, Artist, HomeData, InternetRadio, MusicSourceManager, LyricLine, Playlist, SourceRow, Track, fmtDur
} from '../protocol/MusicSources';
import { CoverColors, Mood, mixHex, withA } from '../common/CoverColors';
import { errText } from '../common/Store';
import { SubApi, SourceCfg, WebDavApi } from '../protocol/MusicSources';
import { buffer, util } from '@kit.ArkTS';
import { DARK_THEME, LIGHT_THEME, Theme } from '../common/Theme';
import { preferences, uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { systemShare } from '@kit.ShareKit';

const Q_BR: number[] = [0, 320, 192, 128];
const BUILD_LABEL: string = 'Meow Core · full core · plain UI';
const Q_NAME: string[] = ['原曲', '320k', '192k', '128k'];

interface SongRowsParam {
  songs: Track[];
}

interface AlbumRowsParam {
  albums: Album[];
}

interface DetailRouteParam {
  kind: string;
  source: string;
  id: string;
}

interface SavedId {
  source: string;
  id: string;
}

interface CachedSongRef {
  source?: string;
  id?: string;
  title: string;
  artist: string;
  album?: string;
  albumId?: string;
  artistId?: string;
  duration?: number;
  cover?: string;
  suffix?: string;
}

interface CachedPlaylistRow {
  id: string;
  name: string;
  songs: CachedSongRef[];
}

interface CachedRemotePlaylistRow {
  source: string;
  id: string;
  name: string;
  songs: CachedSongRef[];
  savedAt: number;
  songCount?: number;
  cover?: string;
  localCover?: string;
}

interface PendingFavoriteOp {
  source: string;
  id: string;
  title: string;
  artist: string;
  album: string;
  liked: boolean;
  createdAt: number;
}

interface PlaylistCacheData {
  favorites: CachedSongRef[];
  playlists: CachedPlaylistRow[];
  remotePlaylists?: CachedRemotePlaylistRow[];
  songIndex?: CachedSongRef[];
  pendingFavorites?: PendingFavoriteOp[];
}

interface PlayStatRow {
  title: string;
  artist: string;
  plays: number;
  seconds: number;
}

interface ArtistStatRow {
  artist: string;
  plays: number;
  seconds: number;
}

interface ListeningStatsData {
  totalSeconds: number;
  totalPlays: number;
  songs: PlayStatRow[];
}

interface MetadataCacheData {
  savedAt: number;
  songs: Track[];
  albums: Album[];
  artists: Artist[];
  playlists: Playlist[];
  liked: Track[];
  newest: Album[];
  recent: Album[];
}

interface LoudnessPlayer {
  setLoudnessGain(gain: number): void;
}

const LOCAL_PLAYLIST_SOURCE: string = 'cache-webdav';
const PLAYLIST_CACHE_PREF: string = 'lumen_playlist_cache';
const PLAYLIST_CACHE_KEY: string = 'playlistCacheV1';
const CLOUD_OFFLINE_MESSAGE: string = '无法连接到音源，请检查音乐源配置是否正确';
const STATS_PREF: string = 'lumen_listening_stats';
const STATS_KEY: string = 'statsV1';
const META_PREF: string = 'lumen_metadata_cache';
const META_KEY: string = 'snapshotV1';
const LOCAL_SOURCE: string = 'local';
const LOCAL_DIR_NAME: string = 'Meow';

@Entry
@Component
struct Player {

  @State tab: number = 0;
  @State lib: number = 1;
  @State page: string = 'main';
  @State err: string = '';
  @State toast: string = '';
  @State newest: Album[] = [];
  @State recent: Album[] = [];
  @State albums: Album[] = [];
  @State songs: Track[] = [];
  @State artists: Artist[] = [];
  @State playlists: Playlist[] = [];
  @State liked: Track[] = [];
  @State sources: SourceRow[] = [];
  @State q: string = '';
  @State hitSongs: Track[] = [];
  @State hitAlbums: Album[] = [];
  @State hitArtists: Artist[] = [];
  @State searchHinting: boolean = false;
  @State searchCommitted: boolean = false;
  @State searchSuggestions: string[] = [];
  @State searchHistory: string[] = [];
  @State followedArtistKeys: string[] = [];
  @State homeFeedSeed: number = 1;
  @State radios: InternetRadio[] = [];
  @State localSongs: Track[] = [];
  @State localImportBusy: boolean = false;
  @State detailTitle: string = '';
  @State detailSub: string = '';
  @State detailCover: string = '';
  @State detailTracks: Track[] = [];
  @State detailKind: string = '';
  @State detailSource: string = '';
  @State detailId: string = '';
  @State nowOpen: boolean = false;
  @State queueOpen: boolean = false;
  @State importOpen: boolean = false;
  @State audioFx: boolean = true;
  @State importCode: string = '';
  @State nowTitle: string = '尚未播放';
  @State nowArtist: string = '从首页挑一张专辑开始';
  @State nowCover: string = '';
  @State nowLiked: boolean = false;
  @State playing: boolean = false;
  @State pos: number = 0;
  @State dur: number = 0;
  @State miniCoverAngle: number = 0;
  @State officialDockPlayer: boolean = false;
  @State qIndex: number = 0;
  // 播放模式：0=随机播放，1=列表循环，2=单曲循环
  @State repeat: number = 0;
  @State lyLines: LyricLine[] = [];
  @State lyIndex: number = 0;
  @State nowPage: number = 0;
  @State idleK: number = 0;
  private idleAt: number = 0;
  @State queue: Track[] = [];
  @State qpos: number = 0;
  @State artistAlbums: Album[] = [];
  @State expand: number = 0;
  @State homeChip: number = 0;
  @State homeRefreshing: boolean = false;
  @State homeScrollY: number = 0;
  @State screenW: number = 390;
  @State screenH: number = 844;
  @State density: number = 3;
  @State pressPlay: boolean = false;
  @State pressSkip: number = 0;
  @State stageFade: number = 1;
  @State qualityOpen: boolean = false;
  @State moreOpen: boolean = false;
  @State sleepPickerOpen: boolean = false;
  @State sleepCustomText: string = '45';
  @State pendingSeek: number = -1;
  @State similarQueryBusy: boolean = false;
  @State similarQueryHintVisible: boolean = false;
  @State sleepMin: number = 0;
  @State sleepEndAt: number = 0;
  @State topPad: number = 48;
  @State botPad: number = 28;
  @State queueDrag: number = 0;
  @State moodGlow: string = '#8A8A8E';
  @State moodSoft: string = '#2C2C2E';
  @State moodDeep: string = '#161618';
  @State dGlow: string = '#8A8A8E';
  @State dSoft: string = '#2C2C2E';
  @State dDeep: string = '#161618';
  @State isDark: boolean = true;
  @State uiTheme: Theme = DARK_THEME;
  @State themeMode: number = 0;
  @State themeRenderSerial: number = 0;
  @State hdsThemeReady: boolean = false;
  @State hdsPlaybackReady: boolean = false;
  private savedQueueIds: SavedId[] = [];
  private tickN: number = 0;
  private scrobbleKey: string = '';
  private scrobbleSubmitted: boolean = false;
  private savePosKey: string = '';
  @StorageProp('lumenOfflineHint') offlineHint: string = '';
  @State lyricsStatus: string = '';
  @State orbA: number = 0;
  @State orbB: number = 0;
  @State orbC: number = 0;
  @State wavePulse: number = 0;
  private waveAnimating: boolean = false;
  private orbsRunning: boolean = false;
  private session: AVSessionManager.AVSession | undefined = undefined;
  private sessPlaying: boolean = false;
  private lvActive: boolean = false;
  private bgActive: boolean = false;
  private lvId: number = 20260830;
  private lvTick: number = 0;
  @State lvState: string = '实况窗：未同步';
  @State plDlgMode: number = 0;
  @State plDlgName: string = '';
  @State manageOpen: boolean = false;
  @State manageName: string = '';
  @State plPickOn: boolean = false;
  @State plPickTitle: string = '';
  private manageSrc: string = '';
  private manageId: string = '';
  private plPickTrack: Track | undefined = undefined;
  private toastAt: number = 0;
  private toastDurationMs: number = 5000;
  private homeRefreshRunning: boolean = false;
  private lastPageSwitch: number = 0;
  // 左右切换播放器页面时，手指可能正好在歌词文字上抬起。
  // parallelGesture 下歌词的 Click 仍可能被识别，因此横向拖动期间短暂禁止歌词 seek。
  private lyricSeekBlockUntil: number = 0;
  @State buildLabel: string = '';
  @State srcName: string = '';
  @State srcUrl: string = '';
  @State srcUser: string = '';
  @State srcPass: string = '';
  @State srcMsg: string = '';
  @State srcOk: boolean = false;
  @State srcBusy: boolean = false;
  @State srcEditId: string = '';
  @State srcKind: string = 'subsonic';
  // 0=仅 NAS（Navidrome），1=仅网盘，2=合并
  @State musicSourceMode: number = 2;
  // 应用图标：default=青色默认，gold/dark/light/neon 为备用图标。
  @State appIconChoice: string = 'default';
  @State appIconFixed: boolean = false;
  @State appIconAutoHoliday: boolean = true;
  @State appIconStatus: string = '';
  private appliedAppIcon: string = '#unknown';
  private appIconCheckAt: number = 0;
  // 高级设置
  @State continueLast: boolean = false;
  @State coexistAudio: boolean = false;
  @State replayGain: boolean = true;
  @State fadeAudio: boolean = false;
  @State forceKaraoke: boolean = false;
  @State lyricSizeMode: number = 1;
  @State uiSizeMode: number = 1;
  @State settingPickerOpen: boolean = false;
  @State settingPickerAction: string = '';
  @State carLyrics: boolean = true;
  @State radioEnabled: boolean = true;
  @State songLoadLimit: number = 500;
  @State albumLoadLimit: number = 200;
  @State artistLoadLimit: number = 200;
  @State audioCacheGB: number = 2;
  @State audioCacheBytes: number = 0;
  @State imageCacheLabel: string = '系统管理';
  @State metadataCacheLabel: string = '未缓存';
  // 本地听歌统计与排行
  @State statTotalSeconds: number = 0;
  @State statTotalPlays: number = 0;
  @State statRows: PlayStatRow[] = [];
  private statMsCarry: number = 0;
  private statRecordedKey: string = '';
  // 网盘收藏/歌单独立保存，不和曲库元数据缓存混在一起。
  private cloudFavoriteRefs: CachedSongRef[] = [];
  private cloudPlaylistRows: CachedPlaylistRow[] = [];
  private remotePlaylistCacheRows: CachedRemotePlaylistRow[] = [];
  private songIndexRefs: CachedSongRef[] = [];
  private pendingFavoriteOps: PendingFavoriteOp[] = [];
  private favoriteSyncRunning: boolean = false;
  @State playlistCacheSongCount: number = 0;
  @State playlistCachePlaylistCount: number = 0;
  private similarQueryHintHandle: number = -1;
  private sleepHandle: number = -1;
  private client: MusicSourceManager = new MusicSourceManager();
  private av: media.AVPlayer | undefined = undefined;
  private downloadTasks: request.agent.Task[] = [];
  private downloadingTrackKeys: string[] = [];
  @State downloadUiSerial: number = 0;
  private timer: number = -1;
  private searchInputController: TextInputController = new TextInputController();
  private lyricScroller: Scroller = new Scroller();
  private homePageScroller: Scroller = new Scroller();
  private standalonePageScroller: Scroller = new Scroller();
  private detailNavStack: NavPathStack = new NavPathStack();
  private playerMotionToken: number = 0;
  private playerTargetOpen: boolean = false;
  // 详情页动画也必须串行化。快速打开/返回/再打开时，旧动画回调不能覆盖新状态。
  // 防止上一张专辑/歌手/歌单的异步请求晚到后覆盖当前详情。
  private detailLoadToken: number = 0;
  private searchToken: number = 0;
  private localPlaybackFd: number = -1;

  t(): Theme {
    return this.uiTheme;
  }

  hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  // 普通文字和图标只认一个前景色：深色纯白，浅色纯黑。
  // 不再让各组件各自从 sub/text2/sheetText 等颜色推断主题。
  themeInk(): string {
    // 让所有黑白前景图标都显式依赖同一个可观察状态。
    // themeRenderSerial 只负责强制重绘，不参与颜色计算。
    const _serial = this.themeRenderSerial;
    if (_serial < 0) return '#000000';
    return this.isDark ? '#FFFFFF' : '#000000';
  }

  themeInkTrack(): string {
    return this.isDark ? '#66FFFFFF' : '#52000000';
  }

  applyThemeState(dark: boolean): void {
    this.isDark = dark;
    this.uiTheme = dark ? DARK_THEME : LIGHT_THEME;
    this.themeRenderSerial++;
    AppStorage.setOrCreate('lumenDark', dark);
    this.applySysBar();
  }

  refreshFollowSystemTheme(): void {
    if (this.themeMode !== 2) return;
    const dark = this.resolveAuto();
    if (dark !== this.isDark) this.applyThemeState(dark);
  }

  resolveAuto(): boolean {
    try {
      const ctx = this.hostContext();
      const cm = ctx.config !== undefined ? ctx.config.colorMode : undefined;
      if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        return false;
      }
      if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        return true;
      }
      // 极少数配置尚未就绪的瞬间保持当前主题，避免“跟随系统”闪到深色。
      return this.isDark;
    } catch (_e) {
      return this.isDark;
    }
  }

  applySystemColorMode(): void {
    try {
      const app = this.hostContext().getApplicationContext();
      if (this.themeMode === 0) {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else if (this.themeMode === 1) {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (_e) {
    }
  }

  applySysBar(): void {
    try {
      const ctx = this.hostContext();
      window.getLastWindow(ctx).then((win: window.Window) => {
        // 全屏播放器始终是封面取色后的深色沉浸表面。即使应用本身处于浅色主题，
        // 状态栏/导航栏也必须使用浅色内容；播放器收起后才恢复跟随全局主题。
        const immersivePlayer = this.nowOpen || this.expand > 0.55;
        const lightBarContent = immersivePlayer || this.isDark;
        const bar: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: lightBarContent ? '#FFFFFF' : '#000000',
          navigationBarContentColor: lightBarContent ? '#FFFFFF' : '#000000'
        };
        win.setWindowSystemBarProperties(bar);
      });
    } catch (_e) {
    }
  }

  iconAltName(choice: string): string {
    if (choice === 'gold') return 'icon_gold';
    if (choice === 'dark') return 'icon_dark';
    if (choice === 'light') return 'icon_light';
    if (choice === 'neon') return 'icon_neon';
    if (choice === 'holiday_april') return 'icon_holiday_april';
    if (choice === 'holiday_children') return 'icon_holiday_children';
    if (choice === 'holiday_spring') return 'icon_holiday_spring';
    return '';
  }

  iconLabel(choice: string): string {
    if (choice === 'gold') return '暖金';
    if (choice === 'dark') return '曜石';
    if (choice === 'light') return '冰白';
    if (choice === 'neon') return '蓝紫霓虹';
    if (choice === 'holiday_april') return '愚人节限定';
    if (choice === 'holiday_children') return '儿童节限定';
    if (choice === 'holiday_spring') return '春节限定';
    return '青色默认';
  }

  holidayIconChoice(now: Date = new Date()): string {
    // 固定公历节日。
    if (now.getMonth() === 3 && now.getDate() === 1) return 'holiday_april'; // 愚人节
    if (now.getMonth() === 5 && now.getDate() === 1) return 'holiday_children'; // 儿童节
    // 春节不维护年份表。Localization Kit 把当前公历日期转换成农历：
    // 除夕（明天是正月初一）到正月十五使用暖金图标。
    try {
      const lunar: i18n.Calendar = i18n.getCalendar('zh-Hans', 'chinese');
      lunar.setTime(now);
      const lunarMonth = Number(lunar.get('month'));
      const lunarDate = Number(lunar.get('date'));
      if (lunarMonth === 0 && lunarDate >= 1 && lunarDate <= 15) return 'holiday_spring';
      const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 12, 0, 0);
      const nextLunar: i18n.Calendar = i18n.getCalendar('zh-Hans', 'chinese');
      nextLunar.setTime(tomorrow);
      if (Number(nextLunar.get('month')) === 0 && Number(nextLunar.get('date')) === 1) return 'holiday_spring';
    } catch (_e) {
    }
    return '';
  }

  holidayIconLabel(now: Date = new Date()): string {
    if (now.getMonth() === 3 && now.getDate() === 1) return '愚人节 · 专属限定图标';
    if (now.getMonth() === 5 && now.getDate() === 1) return '儿童节 · 专属限定图标';
    if (this.holidayIconChoice(now) === 'holiday_spring') return '春节 · 专属限定图标（除夕至正月十五）';
    return '今天没有节日限定图标';
  }

  desiredAppIconChoice(): string {
    if (this.appIconFixed) return this.appIconChoice;
    if (this.appIconAutoHoliday) {
      const holiday = this.holidayIconChoice();
      if (holiday.length > 0) return holiday;
    }
    return 'default';
  }

  async applyAppIcon(force: boolean = false): Promise<void> {
    const choice = this.desiredAppIconChoice();
    const altName = this.iconAltName(choice);
    if (!force && altName === this.appliedAppIcon) return;
    try {
      await bundleManager.setAlternateIcon(altName);
      this.appliedAppIcon = altName;
      this.appIconStatus = '当前使用：' + this.iconLabel(choice);
    } catch (e) {
      const be = e as BusinessError;
      const code = '' + be.code;
      // 17700309 表示当前本来就是默认图标。恢复默认时可以视为成功。
      if (altName.length === 0 && code === '17700309') {
        this.appliedAppIcon = '';
        this.appIconStatus = '当前使用：青色默认';
        return;
      }
      this.appIconStatus = code === '17700307' || code === '17700310'
        ? '切换失败：当前系统主题可能覆盖了应用图标'
        : '图标切换失败' + (be.message.length > 0 ? '：' + be.message : '');
    }
  }

  async loadAppIconPrefs(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      const choice = '' + (await p.get('appIconChoice', 'default'));
      this.appIconChoice = choice === 'gold' || choice === 'dark' || choice === 'light' || choice === 'neon'
        ? choice : 'default';
      this.appIconFixed = '' + (await p.get('appIconFixed', '0')) === '1';
      this.appIconAutoHoliday = '' + (await p.get('appIconAutoHoliday', '1')) !== '0';
    } catch (_e) {
      this.appIconChoice = 'default';
      this.appIconFixed = false;
      this.appIconAutoHoliday = true;
    }
    await this.applyAppIcon(true);
  }

  async saveAppIconPrefs(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      await p.put('appIconChoice', this.appIconChoice);
      await p.put('appIconFixed', this.appIconFixed ? '1' : '0');
      await p.put('appIconAutoHoliday', this.appIconAutoHoliday ? '1' : '0');
      await p.flush();
    } catch (_e) {
    }
    await this.applyAppIcon(true);
  }

  selectAppIcon(choice: string): void {
    this.appIconChoice = choice;
    // 用户点某个图标就是明确的手动选择，自动开启“固定图标”；
    // 关闭固定后才交还给节日自动规则。
    this.appIconFixed = true;
    this.saveAppIconPrefs();
  }

  toggleFixedAppIcon(value: boolean): void {
    this.appIconFixed = value;
    this.saveAppIconPrefs();
  }

  toggleHolidayAppIcon(value: boolean): void {
    this.appIconAutoHoliday = value;
    this.saveAppIconPrefs();
  }

  maybeRefreshAppIcon(): void {
    const now = Date.now();
    if (now - this.appIconCheckAt < 60000) return;
    this.appIconCheckAt = now;
    this.applyAppIcon(false);
  }

  async loadThemePref(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      const mode = Number(await p.get('theme', '0'));
      this.themeMode = mode >= 0 && mode <= 2 ? mode : 0;
      this.applySystemColorMode();
      const dark = this.themeMode === 0 ? true : (this.themeMode === 1 ? false : this.resolveAuto());
      this.applyThemeState(dark);
      if (this.themeMode === 2) {
        // 解除强制色彩模式后，系统 configuration 可能晚几十毫秒才回到真实模式。
        // 做两次轻量复核，避免跟随系统时图标/文字先保留上一主题一小段时间。
        setTimeout(() => { this.refreshFollowSystemTheme(); }, 80);
        setTimeout(() => { this.refreshFollowSystemTheme(); }, 240);
      }
    } catch (_e) {
      // 读取失败也使用当前默认主题继续挂载 HDS，不能让主界面停在等待态。
    } finally {
      this.hdsThemeReady = true;
    }
  }

  themeLabel(): string {
    if (this.themeMode === 1) {
      return '浅色';
    }
    if (this.themeMode === 2) {
      return '跟随系统';
    }
    return '深色';
  }

  async cycleTheme(): Promise<void> {
    this.themeMode = (this.themeMode + 1) % 3;
    this.applySystemColorMode();
    const dark = this.themeMode === 0 ? true : (this.themeMode === 1 ? false : this.resolveAuto());
    this.applyThemeState(dark);
    if (!this.nowOpen) {
      this.expand = 0;
    }
    if (this.themeMode === 2) {
      setTimeout(() => { this.refreshFollowSystemTheme(); }, 80);
      setTimeout(() => { this.refreshFollowSystemTheme(); }, 240);
    }
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      await p.put('theme', '' + this.themeMode);
      await p.flush();
    } catch (_e) {
    }
  }

  async pullMood(url: string, forDetail: boolean): Promise<void> {
    const m: Mood = await CoverColors.of(url);
    if (forDetail) {
      if (this.detailCover === url) {
        this.dGlow = m.glow;
        this.dSoft = m.soft;
        this.dDeep = m.deep;
      }
    } else if (this.nowCover === url) {
      this.moodGlow = m.glow;
      this.moodSoft = m.soft;
      this.moodDeep = m.deep;
    }
  }

  async loadAdvancedPrefs(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      this.continueLast = '' + (await p.get('continueLast', '0')) === '1';
      this.coexistAudio = '' + (await p.get('coexistAudio', '0')) === '1';
      this.replayGain = '' + (await p.get('replayGain', '1')) !== '0';
      this.fadeAudio = '' + (await p.get('fadeAudio', '0')) === '1';
      this.forceKaraoke = '' + (await p.get('forceKaraoke', '0')) === '1';
      this.lyricSizeMode = Number(await p.get('lyricSizeMode', '1'));
      this.uiSizeMode = Number(await p.get('uiSizeMode', '1'));
      this.carLyrics = '' + (await p.get('carLyrics', '1')) !== '0';
      this.radioEnabled = '' + (await p.get('radioEnabled', '1')) !== '0';
      this.songLoadLimit = Number(await p.get('songLoadLimit', '500'));
      this.albumLoadLimit = Number(await p.get('albumLoadLimit', '200'));
      this.artistLoadLimit = Number(await p.get('artistLoadLimit', '200'));
      this.audioCacheGB = Number(await p.get('audioCacheGB', '2'));
      if (this.lyricSizeMode < 0 || this.lyricSizeMode > 2) this.lyricSizeMode = 1;
      if (this.uiSizeMode < 0 || this.uiSizeMode > 2) this.uiSizeMode = 1;
      if (this.songLoadLimit <= 0) this.songLoadLimit = 500;
      if (this.albumLoadLimit <= 0) this.albumLoadLimit = 200;
      if (this.artistLoadLimit <= 0) this.artistLoadLimit = 200;
      if (this.audioCacheGB <= 0) this.audioCacheGB = 2;
      this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
      this.refreshCacheInfo();
    } catch (_e) {
      this.client.setLoadLimits(500, 200, 200);
    }
  }

  async saveAdvancedValue(key: string, value: string): Promise<void> {
    await this.preferencesPut(key, value);
  }

  setAdvancedBool(key: string, value: boolean): void {
    if (key === 'continueLast') this.continueLast = value;
    else if (key === 'coexistAudio') this.coexistAudio = value;
    else if (key === 'replayGain') this.replayGain = value;
    else if (key === 'fadeAudio') this.fadeAudio = value;
    else if (key === 'forceKaraoke') this.forceKaraoke = value;
    else if (key === 'carLyrics') this.carLyrics = value;
    else if (key === 'radioEnabled') {
      this.radioEnabled = value;
      if (!value && this.lib === 6) this.lib = 1;
    }
    this.saveAdvancedValue(key, value ? '1' : '0');
    if (key === 'coexistAudio' && this.av !== undefined) this.applyInterruptMode(this.av);
  }

  lyricSizeLabel(): string {
    return this.lyricSizeMode === 0 ? '小' : (this.lyricSizeMode === 2 ? '大' : '标准');
  }

  interfaceSizeLabel(): string {
    return this.uiSizeMode === 0 ? '紧凑' : (this.uiSizeMode === 2 ? '大' : '标准');
  }


  lyricBaseSize(active: boolean): number {
    const add = this.lyricSizeMode === 0 ? -3 : (this.lyricSizeMode === 2 ? 4 : 0);
    return (active ? 28 : 20) + add;
  }

  lyricLitCount(i: number): number {
    if (i < 0 || i >= this.lyLines.length) return 0;
    const start = this.lyLines[i].t;
    let end = start + 4;
    if (i + 1 < this.lyLines.length && this.lyLines[i + 1].t > start + 0.2) end = this.lyLines[i + 1].t;
    const span = Math.max(0.4, end - start);
    const p = Math.max(0, Math.min(1, (this.pos - start) / span));
    return Math.max(0, Math.min(this.lyLines[i].line.length, Math.floor(this.lyLines[i].line.length * p)));
  }

  cycleLyricSize(): void {
    this.lyricSizeMode = (this.lyricSizeMode + 1) % 3;
    this.saveAdvancedValue('lyricSizeMode', '' + this.lyricSizeMode);
  }

  cycleInterfaceSize(): void {
    this.uiSizeMode = (this.uiSizeMode + 1) % 3;
    this.saveAdvancedValue('uiSizeMode', '' + this.uiSizeMode);
    this.setToast('界面字号与图标将在重启应用后完全生效');
  }

  cycleSongLoadLimit(): void {
    const values: number[] = [200, 500, 1000, 2000];
    let idx = values.indexOf(this.songLoadLimit);
    idx = (idx + 1) % values.length;
    this.songLoadLimit = values[idx];
    this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
    this.saveAdvancedValue('songLoadLimit', '' + this.songLoadLimit);
  }

  cycleAlbumLoadLimit(): void {
    const values: number[] = [100, 200, 500, 1000];
    let idx = values.indexOf(this.albumLoadLimit);
    idx = (idx + 1) % values.length;
    this.albumLoadLimit = values[idx];
    this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
    this.saveAdvancedValue('albumLoadLimit', '' + this.albumLoadLimit);
  }

  cycleArtistLoadLimit(): void {
    const values: number[] = [100, 200, 500, 1000];
    let idx = values.indexOf(this.artistLoadLimit);
    idx = (idx + 1) % values.length;
    this.artistLoadLimit = values[idx];
    this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
    this.saveAdvancedValue('artistLoadLimit', '' + this.artistLoadLimit);
  }

  cycleAudioCacheGB(): void {
    const values: number[] = [1, 2, 4, 8];
    let idx = values.indexOf(this.audioCacheGB);
    idx = (idx + 1) % values.length;
    this.audioCacheGB = values[idx];
    this.saveAdvancedValue('audioCacheGB', '' + this.audioCacheGB);
  }

  settingPickerTitle(): string {
    if (this.settingPickerAction === 'lyricSize') return '歌词字号';
    if (this.settingPickerAction === 'interfaceSize') return '界面字号与图标';
    if (this.settingPickerAction === 'theme') return '主题';
    if (this.settingPickerAction === 'songLimit') return '歌曲单次加载数量';
    if (this.settingPickerAction === 'albumLimit') return '专辑单次加载数量';
    if (this.settingPickerAction === 'artistLimit') return '歌手单次加载数量';
    if (this.settingPickerAction === 'audioCacheGB') return '歌曲最大缓存容量';
    return '选择';
  }

  settingPickerOptions(): string[] {
    if (this.settingPickerAction === 'lyricSize') return ['小', '标准', '大'];
    if (this.settingPickerAction === 'interfaceSize') return ['紧凑', '标准', '大'];
    if (this.settingPickerAction === 'theme') return ['深色', '浅色', '跟随系统'];
    if (this.settingPickerAction === 'songLimit') return ['200', '500', '1000', '2000'];
    if (this.settingPickerAction === 'albumLimit') return ['100', '200', '500', '1000'];
    if (this.settingPickerAction === 'artistLimit') return ['100', '200', '500', '1000'];
    if (this.settingPickerAction === 'audioCacheGB') return ['1 GB', '2 GB', '4 GB', '8 GB'];
    return [];
  }

  settingValueLabel(action: string): string {
    if (action === 'lyricSize') return this.lyricSizeLabel();
    if (action === 'interfaceSize') return this.interfaceSizeLabel();
    if (action === 'theme') return this.themeLabel();
    if (action === 'songLimit') return '' + this.songLoadLimit;
    if (action === 'albumLimit') return '' + this.albumLoadLimit;
    if (action === 'artistLimit') return '' + this.artistLoadLimit;
    if (action === 'audioCacheGB') return this.audioCacheGB + ' GB';
    return '';
  }

  settingPickerSelectedIndex(): number {
    if (this.settingPickerAction === 'lyricSize') return this.lyricSizeMode;
    if (this.settingPickerAction === 'interfaceSize') return this.uiSizeMode;
    if (this.settingPickerAction === 'theme') return this.themeMode;
    if (this.settingPickerAction === 'songLimit') return [200, 500, 1000, 2000].indexOf(this.songLoadLimit);
    if (this.settingPickerAction === 'albumLimit') return [100, 200, 500, 1000].indexOf(this.albumLoadLimit);
    if (this.settingPickerAction === 'artistLimit') return [100, 200, 500, 1000].indexOf(this.artistLoadLimit);
    if (this.settingPickerAction === 'audioCacheGB') return [1, 2, 4, 8].indexOf(this.audioCacheGB);
    return -1;
  }

  openSettingPicker(action: string): void {
    this.settingPickerAction = action;
    this.settingPickerOpen = true;
  }

  applySettingChoice(index: number): void {
    const action = this.settingPickerAction;
    if (action === 'lyricSize') {
      this.lyricSizeMode = Math.max(0, Math.min(2, index));
      this.saveAdvancedValue('lyricSizeMode', '' + this.lyricSizeMode);
    } else if (action === 'interfaceSize') {
      this.uiSizeMode = Math.max(0, Math.min(2, index));
      this.saveAdvancedValue('uiSizeMode', '' + this.uiSizeMode);
      this.setToast('界面字号与图标将在重启应用后完全生效');
    } else if (action === 'theme') {
      this.themeMode = Math.max(0, Math.min(2, index));
      this.applySystemColorMode();
      const dark = this.themeMode === 0 ? true : (this.themeMode === 1 ? false : this.resolveAuto());
      this.applyThemeState(dark);
      if (!this.nowOpen) {
        this.expand = 0;
      }
      if (this.themeMode === 2) {
        setTimeout(() => { this.refreshFollowSystemTheme(); }, 80);
        setTimeout(() => { this.refreshFollowSystemTheme(); }, 240);
      }
      this.saveAdvancedValue('theme', '' + this.themeMode);    } else if (action === 'songLimit') {
      const values: number[] = [200, 500, 1000, 2000];
      if (index >= 0 && index < values.length) this.songLoadLimit = values[index];
      this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
      this.saveAdvancedValue('songLoadLimit', '' + this.songLoadLimit);
    } else if (action === 'albumLimit') {
      const values: number[] = [100, 200, 500, 1000];
      if (index >= 0 && index < values.length) this.albumLoadLimit = values[index];
      this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
      this.saveAdvancedValue('albumLoadLimit', '' + this.albumLoadLimit);
    } else if (action === 'artistLimit') {
      const values: number[] = [100, 200, 500, 1000];
      if (index >= 0 && index < values.length) this.artistLoadLimit = values[index];
      this.client.setLoadLimits(this.songLoadLimit, this.albumLoadLimit, this.artistLoadLimit);
      this.saveAdvancedValue('artistLoadLimit', '' + this.artistLoadLimit);
    } else if (action === 'audioCacheGB') {
      const values: number[] = [1, 2, 4, 8];
      if (index >= 0 && index < values.length) this.audioCacheGB = values[index];
      this.saveAdvancedValue('audioCacheGB', '' + this.audioCacheGB);
    }
    this.settingPickerOpen = false;
  }


  applyInterruptMode(player: media.AVPlayer): void {
    try {
      player.audioInterruptMode = this.coexistAudio
        ? audio.InterruptMode.SHARE_MODE
        : audio.InterruptMode.INDEPENDENT_MODE;
    } catch (_e) {
    }
  }

  beginFadeIn(player: media.AVPlayer): void {
    try {
      if (!this.fadeAudio) {
        player.setVolume(1);
        return;
      }
      player.setVolume(0);
      let step = 0;
      const handle = setInterval(() => {
        step++;
        try {
          player.setVolume(Math.min(1, step / 8));
        } catch (_e) {
          clearInterval(handle);
        }
        if (step >= 8) clearInterval(handle);
      }, 45);
    } catch (_e) {
    }
  }

  formatBytes(n: number): string {
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
    return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  }

  refreshCacheInfo(): void {
    try {
      const ctx = this.hostContext();
      const dir = ctx.cacheDir + '/downloads';
      let bytes = 0;
      if (fileIo.accessSync(dir)) {
        const names = fileIo.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          try {
            const st = fileIo.statSync(dir + '/' + names[i]);
            if (st.isFile()) bytes += Number(st.size);
          } catch (_e) {
          }
        }
      }
      this.audioCacheBytes = bytes;
      this.imageCacheLabel = CoverColors.cacheCount() + ' 个封面取色记录';
    } catch (_e) {
      this.audioCacheBytes = 0;
    }
  }

  clearAudioCache(): void {
    try {
      const ctx = this.hostContext();
      const dir = ctx.cacheDir + '/downloads';
      if (fileIo.accessSync(dir)) {
        const names = fileIo.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          const path = dir + '/' + names[i];
          try { if (fileIo.statSync(path).isFile()) fileIo.unlinkSync(path); } catch (_e) {}
        }
      }
      this.refreshCacheInfo();
      this.setToast('已清理音频临时缓存');
    } catch (_e) {
      this.setToast('清理音频缓存失败');
    }
  }

  clearImageCache(): void {
    CoverColors.clear();
    this.refreshCacheInfo();
    this.setToast('已清理图片取色缓存');
  }

  async saveMetadataSnapshot(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, META_PREF);
      const data: MetadataCacheData = {
        savedAt: Date.now(), songs: this.songs, albums: this.albums, artists: this.artists,
        playlists: this.playlists, liked: this.liked, newest: this.newest, recent: this.recent
      };
      const raw = JSON.stringify(data);
      await p.put(META_KEY, raw);
      await p.flush();
      this.metadataCacheLabel = '已缓存 ' + this.songs.length + ' 首 · ' + this.formatBytes(raw.length);
    } catch (_e) {
    }
  }

  async readMetadataSnapshotData(): Promise<MetadataCacheData | undefined> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, META_PREF);
      const raw = '' + (await p.get(META_KEY, ''));
      if (raw.length < 2) return undefined;
      return JSON.parse(raw) as MetadataCacheData;
    } catch (_e) {
      return undefined;
    }
  }

  async loadMetadataSnapshot(): Promise<boolean> {
    const data = await this.readMetadataSnapshotData();
    if (data === undefined) return false;
    this.songs = data.songs !== undefined ? data.songs : [];
    this.albums = data.albums !== undefined ? data.albums : [];
    this.artists = data.artists !== undefined ? data.artists : [];
    this.playlists = data.playlists !== undefined ? data.playlists : [];
    this.liked = data.liked !== undefined ? data.liked : [];
    this.newest = data.newest !== undefined ? data.newest : [];
    this.recent = data.recent !== undefined ? data.recent : [];
    this.metadataCacheLabel = '已缓存 ' + this.songs.length + ' 首';
    return true;
  }

  async clearMetadataCache(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, META_PREF);
      await p.put(META_KEY, '');
      await p.flush();
      this.metadataCacheLabel = '未缓存';
      this.setToast('已清理元数据缓存');
    } catch (_e) {
      this.setToast('清理元数据缓存失败');
    }
  }

  async loadStats(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, STATS_PREF);
      const raw = '' + (await p.get(STATS_KEY, ''));
      if (raw.length < 2) return;
      const data = JSON.parse(raw) as ListeningStatsData;
      this.statTotalSeconds = data.totalSeconds;
      this.statTotalPlays = data.totalPlays;
      this.statRows = data.songs !== undefined ? data.songs : [];
    } catch (_e) {
    }
  }

  async saveStats(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, STATS_PREF);
      const data: ListeningStatsData = {
        totalSeconds: this.statTotalSeconds,
        totalPlays: this.statTotalPlays,
        songs: this.statRows
      };
      await p.put(STATS_KEY, JSON.stringify(data));
      await p.flush();
    } catch (_e) {
    }
  }

  statRow(t: Track): PlayStatRow {
    for (let i = 0; i < this.statRows.length; i++) {
      if (this.cacheNorm(this.statRows[i].title) === this.cacheNorm(t.title) &&
        this.cacheNorm(this.statRows[i].artist) === this.cacheNorm(t.artist)) {
        return this.statRows[i];
      }
    }
    const row: PlayStatRow = { title: t.title, artist: t.artist, plays: 0, seconds: 0 };
    this.statRows.push(row);
    return row;
  }

  recordListeningTick(): void {
    if (!this.playing) return;
    const t = this.current();
    if (t === undefined) return;
    this.statMsCarry += 400;
    if (this.statMsCarry < 1000) return;
    const sec = Math.floor(this.statMsCarry / 1000);
    this.statMsCarry -= sec * 1000;
    this.statTotalSeconds += sec;
    const row = this.statRow(t);
    row.seconds += sec;
    if (this.tickN % 15 === 0) {
      this.statRows = this.statRows.slice();
      this.saveStats();
    }
  }

  recordStatPlay(t: Track): void {
    const key = this.cacheNorm(t.artist) + '/' + this.cacheNorm(t.title) + '/' + this.scrobbleKey;
    if (this.statRecordedKey === key) return;
    this.statRecordedKey = key;
    const row = this.statRow(t);
    row.plays++;
    this.statTotalPlays++;
    this.statRows = this.statRows.slice();
    this.saveStats();
  }

  topSongStats(): PlayStatRow[] {
    const rows = this.statRows.slice();
    rows.sort((a: PlayStatRow, b: PlayStatRow) => b.plays === a.plays ? b.seconds - a.seconds : b.plays - a.plays);
    return rows.length > 10 ? rows.slice(0, 10) : rows;
  }

  topArtistStats(): ArtistStatRow[] {
    const out: ArtistStatRow[] = [];
    for (let i = 0; i < this.statRows.length; i++) {
      const src = this.statRows[i];
      let hit: ArtistStatRow | undefined = undefined;
      for (let j = 0; j < out.length; j++) {
        if (this.cacheNorm(out[j].artist) === this.cacheNorm(src.artist)) { hit = out[j]; break; }
      }
      if (hit === undefined) {
        const row: ArtistStatRow = { artist: src.artist, plays: src.plays, seconds: src.seconds };
        out.push(row);
      } else {
        hit.plays += src.plays;
        hit.seconds += src.seconds;
      }
    }
    out.sort((a: ArtistStatRow, b: ArtistStatRow) => b.plays === a.plays ? b.seconds - a.seconds : b.plays - a.plays);
    return out.length > 10 ? out.slice(0, 10) : out;
  }

  statTimeLabel(seconds: number): string {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (h > 0) return h + ' 小时 ' + m + ' 分钟';
    return m + ' 分钟';
  }

  libraryTabs(): string[] {
    const rows: string[] = ['歌曲', '专辑', '艺人'];
    if (this.radioEnabled) rows.push('电台');
    return rows;
  }

  localRootDir(): string {
    const ctx = this.hostContext();
    return ctx.filesDir + '/' + LOCAL_DIR_NAME;
  }

  localDownloadDir(): string {
    return this.localRootDir() + '/download';
  }

  ensureLocalFolders(): void {
    try {
      const root = this.localRootDir();
      if (!fileIo.accessSync(root)) fileIo.mkdirSync(root);
      const download = root + '/download';
      if (!fileIo.accessSync(download)) fileIo.mkdirSync(download);
    } catch (_e) {
    }
  }

  isLocalAudioName(name: string): boolean {
    const dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    const ext = name.substring(dot + 1).toLowerCase();
    return ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'ape', 'alac'].indexOf(ext) >= 0;
  }

  localTrackFromPath(path: string): Track {
    const slash = path.lastIndexOf('/');
    const fileName = slash >= 0 ? path.substring(slash + 1) : path;
    const dot = fileName.lastIndexOf('.');
    const stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    const suffix = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    let title = stem;
    let artist = '本地音乐';
    const sep = stem.indexOf(' - ');
    if (sep > 0 && sep < stem.length - 3) {
      artist = stem.substring(0, sep).trim();
      title = stem.substring(sep + 3).trim();
    }
    const parentPath = slash > 0 ? path.substring(0, slash) : '';
    const parentSlash = parentPath.lastIndexOf('/');
    let album = parentSlash >= 0 ? parentPath.substring(parentSlash + 1) : LOCAL_DIR_NAME;
    if (album.toLowerCase() === 'download' || album === LOCAL_DIR_NAME) album = '本地音乐';
    return {
      id: 'local:' + path,
      source: LOCAL_SOURCE,
      title: title.length > 0 ? title : fileName,
      artist: artist,
      album: album,
      albumId: '',
      artistId: '',
      duration: 0,
      liked: this.isCachedFavorite({ source: LOCAL_SOURCE, id: 'local:' + path, title: title.length > 0 ? title : fileName, artist: artist }),
      cover: '',
      stream: path,
      suffix: suffix,
      available: true
    };
  }

  scanLocalDir(path: string, rows: Track[]): void {
    let names: string[] = [];
    try { names = fileIo.listFileSync(path); } catch (_e) { return; }
    for (let i = 0; i < names.length; i++) {
      const full = path + '/' + names[i];
      try {
        const st = fileIo.statSync(full);
        if (st.isDirectory()) {
          this.scanLocalDir(full, rows);
        } else if (st.isFile() && this.isLocalAudioName(names[i])) {
          rows.push(this.localTrackFromPath(full));
        }
      } catch (_e) {
      }
    }
  }

  scanLocalLibrary(): void {
    this.ensureLocalFolders();
    const rows: Track[] = [];
    this.scanLocalDir(this.localRootDir(), rows);
    rows.sort((a: Track, b: Track) => {
      const ak = a.artist + '\u0000' + a.title;
      const bk = b.artist + '\u0000' + b.title;
      if (ak < bk) return -1;
      if (ak > bk) return 1;
      return 0;
    });
    this.localSongs = rows;
    this.enrichLocalSongsFromNas();
  }

  localTrackPath(t: Track): string {
    if (t.source !== LOCAL_SOURCE || t.id.indexOf('local:') !== 0) return '';
    return t.id.substring(6);
  }

  downloadedLocalRows(): Track[] {
    const dir = this.localDownloadDir() + '/';
    const rows: Track[] = [];
    for (let i = 0; i < this.localSongs.length; i++) {
      const path = this.localTrackPath(this.localSongs[i]);
      if (path.indexOf(dir) === 0) rows.push(this.localSongs[i]);
    }
    return rows;
  }

  downloadedFileBytes(t: Track): number {
    const path = this.localTrackPath(t);
    if (path.length === 0) return 0;
    try { return Number(fileIo.statSync(path).size); } catch (_e) { return 0; }
  }

  downloadedTotalBytes(): number {
    const rows = this.downloadedLocalRows();
    let bytes = 0;
    for (let i = 0; i < rows.length; i++) bytes += this.downloadedFileBytes(rows[i]);
    return bytes;
  }

  activeDownloadCount(): number {
    const _serial = this.downloadUiSerial;
    if (_serial < 0) return 0;
    return this.downloadingTrackKeys.length;
  }

  deleteDownloadedTrack(t: Track): void {
    if (this.isCurrentTrack(t)) {
      this.setToast('正在播放这首本地歌曲，请切歌后再删除');
      return;
    }
    const path = this.localTrackPath(t);
    if (path.length === 0 || path.indexOf(this.localDownloadDir() + '/') !== 0) return;
    try {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      this.scanLocalLibrary();
      this.downloadUiSerial++;
      this.setToast('已删除下载：' + t.title);
    } catch (e) {
      this.setToast('删除失败：' + errText(e as Object));
    }
  }

  async importLocalMusic(): Promise<void> {
    if (this.localImportBusy) return;
    this.localImportBusy = true;
    try {
      this.ensureLocalFolders();
      const ctx = this.hostContext();
      const options = new picker.AudioSelectOptions();
      options.maxSelectNumber = 500;
      const audioPicker = new picker.AudioViewPicker(ctx);
      const uris = await audioPicker.select(options);
      let imported = 0;
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        let fileName = 'import-' + Date.now() + '-' + i + '.mp3';
        try {
          const raw = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
          if (this.isLocalAudioName(raw)) fileName = this.safeDownloadName(raw);
        } catch (_e) {
        }
        let target = this.localRootDir() + '/' + fileName;
        if (fileIo.accessSync(target)) {
          const dot = fileName.lastIndexOf('.');
          const stem = dot > 0 ? fileName.substring(0, dot) : fileName;
          const ext = dot > 0 ? fileName.substring(dot) : '';
          target = this.localRootDir() + '/' + stem + '-' + Date.now() + ext;
        }
        try {
          const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
          const dst = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
          fileIo.copyFileSync(src.fd, dst.fd);
          fileIo.closeSync(src);
          fileIo.closeSync(dst);
          imported++;
        } catch (_e) {
        }
      }
      this.scanLocalLibrary();
      this.setToast(imported > 0 ? ('已导入 ' + imported + ' 首到 Meow') : '没有导入新的本地音乐');
    } catch (e) {
      const msg = errText(e as Object);
      if (msg.indexOf('cancel') < 0 && msg.indexOf('取消') < 0) this.setToast('导入本地音乐失败：' + msg);
    } finally {
      this.localImportBusy = false;
    }
  }

  localSearchRows(query: string): Track[] {
    const key = query.trim().toLowerCase();
    const rows: Track[] = [];
    if (key.length === 0) return rows;
    for (let i = 0; i < this.localSongs.length && rows.length < 30; i++) {
      const t = this.localSongs[i];
      if ((t.title + ' ' + t.artist + ' ' + t.album).toLowerCase().indexOf(key) >= 0) rows.push(t);
    }
    return rows;
  }

  sameSongIdentity(a: Track, b: Track): boolean {
    return this.cacheNorm(a.title) === this.cacheNorm(b.title) &&
      this.cacheNorm(a.artist) === this.cacheNorm(b.artist);
  }

  localCopyFor(t: Track): Track | undefined {
    if (this.client.sourceType(t.source) === 'local') return t;
    for (let i = 0; i < this.localSongs.length; i++) {
      if (this.sameSongIdentity(this.localSongs[i], t)) return this.localSongs[i];
    }
    return undefined;
  }

  preferLocalTrack(t: Track): Track {
    const local = this.localCopyFor(t);
    if (local === undefined || local === t) return t;
    return {
      id: local.id, source: LOCAL_SOURCE, title: t.title, artist: t.artist,
      album: t.album.length > 0 ? t.album : local.album, albumId: '', artistId: '',
      duration: t.duration > 0 ? t.duration : local.duration, liked: t.liked,
      cover: t.cover, stream: local.stream, suffix: local.suffix, replayGainDb: t.replayGainDb,
      available: true, cached: true
    };
  }

  pendingFavoriteStateFor(t: Track): boolean | undefined {
    for (let i = this.pendingFavoriteOps.length - 1; i >= 0; i--) {
      if (this.pendingFavoriteSame(this.pendingFavoriteOps[i], t)) return this.pendingFavoriteOps[i].liked;
    }
    return undefined;
  }

  enrichLocalSongsFromNas(): void {
    if (!this.hasOnlineMusicSource() || this.localSongs.length === 0 || this.songs.length === 0) return;
    const out: Track[] = [];
    for (let i = 0; i < this.localSongs.length; i++) {
      const local = this.localSongs[i];
      const target = this.findNasMatchForPending({ source: LOCAL_SOURCE, id: local.id,
        title: local.title, artist: local.artist, album: local.album, liked: local.liked, createdAt: 0 });
      if (target === undefined) {
        out.push(local);
        continue;
      }
      const pending = this.pendingFavoriteStateFor(local);
      out.push({ id: local.id, source: LOCAL_SOURCE,
        title: target.title.length > 0 ? target.title : local.title,
        artist: target.artist.length > 0 ? target.artist : local.artist,
        album: target.album.length > 0 ? target.album : local.album,
        albumId: target.albumId, artistId: target.artistId,
        duration: target.duration > 0 ? target.duration : local.duration,
        liked: pending !== undefined ? pending : (target.liked || local.liked),
        cover: target.cover, stream: local.stream, suffix: local.suffix,
        replayGainDb: target.replayGainDb, available: true, cached: true });
    }
    this.localSongs = out;
  }

  mergedDiscoverableSongs(): Track[] {
    const rows: Track[] = [];
    for (let i = 0; i < this.localSongs.length; i++) {
      let enriched: Track = this.localSongs[i];
      for (let j = 0; j < this.songs.length; j++) {
        if (this.sameSongIdentity(this.localSongs[i], this.songs[j])) {
          enriched = this.preferLocalTrack(this.songs[j]);
          break;
        }
      }
      rows.push(enriched);
    }
    for (let i = 0; i < this.songs.length; i++) {
      const t = this.songs[i];
      if (t.available === false) continue;
      let hasLocal = false;
      for (let j = 0; j < this.localSongs.length; j++) {
        if (this.sameSongIdentity(this.localSongs[j], t)) { hasLocal = true; break; }
      }
      if (!hasLocal) rows.push(t);
    }
    return rows;
  }

  appendSearchSuggestion(rows: string[], value: string, key: string): void {
    const text = value.trim();
    const needle = key.trim().toLowerCase();
    if (text.length === 0 || needle.length === 0 || text.toLowerCase().indexOf(needle) < 0) return;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].toLowerCase() === text.toLowerCase()) return;
    }
    if (rows.length < 16) rows.push(text);
  }

  localSearchSuggestions(query: string): string[] {
    const rows: string[] = [];
    const key = query.trim();
    if (key.length === 0) return rows;
    this.appendSearchSuggestion(rows, key, key);
    for (let i = 0; i < this.localSongs.length && rows.length < 16; i++) {
      const t = this.localSongs[i];
      this.appendSearchSuggestion(rows, t.title, key);
      this.appendSearchSuggestion(rows, t.album, key);
      this.appendSearchSuggestion(rows, t.artist, key);
    }
    for (let i = 0; i < this.songs.length && rows.length < 16; i++) {
      const t = this.songs[i];
      this.appendSearchSuggestion(rows, t.title, key);
      this.appendSearchSuggestion(rows, t.album, key);
      this.appendSearchSuggestion(rows, t.artist, key);
    }
    for (let i = 0; i < this.albums.length && rows.length < 16; i++) {
      this.appendSearchSuggestion(rows, this.albums[i].title, key);
      this.appendSearchSuggestion(rows, this.albums[i].artist, key);
    }
    for (let i = 0; i < this.artists.length && rows.length < 16; i++) {
      this.appendSearchSuggestion(rows, this.artists[i].name, key);
    }
    return rows;
  }

  async updateSearchSuggestions(query: string, token: number): Promise<void> {
    const key = query.trim();
    if (key.length === 0) return;
    const rows = this.localSearchSuggestions(key);
    if (token === this.searchToken && !this.searchCommitted) {
      this.searchSuggestions = rows.slice();
      this.searchHinting = true;
    }
    try {
      const r = await this.client.search(key);
      if (token !== this.searchToken || this.searchCommitted || this.q.trim() !== key) return;
      for (let i = 0; i < r.songs.length && rows.length < 16; i++) {
        this.appendSearchSuggestion(rows, r.songs[i].title, key);
        this.appendSearchSuggestion(rows, r.songs[i].album, key);
        this.appendSearchSuggestion(rows, r.songs[i].artist, key);
      }
      for (let i = 0; i < r.albums.length && rows.length < 16; i++) {
        this.appendSearchSuggestion(rows, r.albums[i].title, key);
        this.appendSearchSuggestion(rows, r.albums[i].artist, key);
      }
      for (let i = 0; i < r.artists.length && rows.length < 16; i++) {
        this.appendSearchSuggestion(rows, r.artists[i].name, key);
      }
      this.searchSuggestions = rows.slice();
    } catch (_e) {
      // 联想失败时保留本地候选；正式搜索才显示错误。
    } finally {
      if (token === this.searchToken && !this.searchCommitted) this.searchHinting = false;
    }
  }

  async runSearch(query: string, token: number): Promise<void> {
    const key = query.trim();
    if (key.length === 0) {
      if (token === this.searchToken) {
        this.hitSongs = [];
        this.hitAlbums = [];
        this.hitArtists = [];
        this.searchHinting = false;
      }
      return;
    }
    if (token === this.searchToken) this.searchHinting = true;
    const local = this.localSearchRows(key);
    try {
      const r = await this.client.search(key);
      if (token !== this.searchToken || !this.searchCommitted) return;
      const merged: Track[] = local.slice();
      for (let i = 0; i < r.songs.length; i++) {
        let duplicate = false;
        for (let j = 0; j < local.length; j++) {
          if (this.sameSongIdentity(local[j], r.songs[i])) { duplicate = true; break; }
        }
        if (!duplicate) merged.push(r.songs[i]);
      }
      this.hitSongs = merged.length > 80 ? merged.slice(0, 80) : merged;
      this.markCloudLikes(this.hitSongs);
      this.hitSongs = this.hitSongs.slice();
      this.hitAlbums = r.albums;
      this.hitArtists = r.artists;
      this.err = '';
    } catch (e) {
      if (token === this.searchToken && this.searchCommitted) {
        this.hitSongs = local.slice();
        this.hitAlbums = [];
        this.hitArtists = [];
        if (local.length === 0) this.err = '' + e;
      }
    } finally {
      if (token === this.searchToken) this.searchHinting = false;
    }
  }

  scheduleSearchSuggestion(value: string): void {
    this.q = value;
    this.searchCommitted = false;
    this.hitSongs = [];
    this.hitAlbums = [];
    this.hitArtists = [];
    const token = ++this.searchToken;
    const key = value.trim();
    if (key.length === 0) {
      this.searchSuggestions = [];
      this.searchHinting = false;
      return;
    }
    this.searchSuggestions = this.localSearchSuggestions(key);
    this.searchHinting = true;
    setTimeout(() => {
      if (token === this.searchToken && !this.searchCommitted) this.updateSearchSuggestions(value, token);
    }, 180);
  }

  async loadSearchHistory(): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.hostContext(), 'lumen');
      const raw = '' + await p.get('searchHistoryV1', '');
      const parts = raw.length > 0 ? raw.split('\u001F') : [];
      const rows: string[] = [];
      for (let i = 0; i < parts.length && rows.length < 20; i++) {
        const item = parts[i].trim();
        if (item.length > 0) rows.push(item);
      }
      this.searchHistory = rows;
    } catch (_e) {
      this.searchHistory = [];
    }
  }

  async saveSearchHistory(): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.hostContext(), 'lumen');
      await p.put('searchHistoryV1', this.searchHistory.join('\u001F'));
      await p.flush();
    } catch (_e) {
    }
  }

  rememberSearch(query: string): void {
    const key = query.trim();
    if (key.length === 0) return;
    const rows: string[] = [key];
    for (let i = 0; i < this.searchHistory.length && rows.length < 20; i++) {
      if (this.searchHistory[i].toLowerCase() !== key.toLowerCase()) rows.push(this.searchHistory[i]);
    }
    this.searchHistory = rows;
    this.saveSearchHistory();
  }

  removeSearchHistory(item: string): void {
    const rows: string[] = [];
    for (let i = 0; i < this.searchHistory.length; i++) {
      if (this.searchHistory[i] !== item) rows.push(this.searchHistory[i]);
    }
    this.searchHistory = rows;
    this.saveSearchHistory();
  }

  clearSearchHistory(): void {
    this.searchHistory = [];
    this.saveSearchHistory();
  }

  async commitSearch(query: string): Promise<void> {
    const key = query.trim();
    if (key.length === 0) return;
    // 提交搜索或点击联想词时立即退出编辑态，避免结果页仍被系统输入法顶住。
    try { this.searchInputController.stopEditing(); } catch (_e) {}
    this.q = key;
    this.searchCommitted = true;
    this.searchSuggestions = [];
    this.rememberSearch(key);
    const token = ++this.searchToken;
    await this.runSearch(key, token);
  }

  radioTrack(r: InternetRadio): Track {
    return {
      id: 'radio:' + r.source + ':' + r.id,
      source: r.source,
      title: r.name,
      artist: '网络电台',
      album: 'Internet Radio',
      albumId: '',
      artistId: '',
      duration: 0,
      liked: false,
      cover: '',
      stream: r.streamUrl,
      suffix: 'radio',
      available: true
    };
  }

  async playRadio(r: InternetRadio): Promise<void> {
    const t = this.radioTrack(r);
    this.queue = [t];
    this.qpos = 0;
    await this.playCurrent();
  }

  aboutToAppear(): void {
    this.nowPage = 0;
    this.idleAt = Date.now();
    this.boot();
    this.restoreState();
    this.loadThemePref();
    this.loadAppIconPrefs();
    this.loadStats();
    this.loadSearchHistory();
    this.loadFollowedArtists();
    this.homeFeedSeed = Date.now();
    this.scanLocalLibrary();
    this.measurePads();
    try {
      display.on('change', () => {
        this.measurePads();
      });
    } catch (_e) {
    }
    this.timer = setInterval(() => {
      this.tick();
    }, 400);
    setTimeout(() => { this.startWavePulse(); }, 80);
  }

  async measurePads(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const win = await window.getLastWindow(ctx);
      const density = display.getDefaultDisplaySync().densityPixels;
      const den = density > 1 ? density : 3;
      this.density = den;
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topPx = sys.topRect.height;
      const botPx = nav.bottomRect.height;
      this.topPad = topPx > 20 ? topPx / den : 44;
      this.botPad = (botPx > 8 ? botPx / den : 20) + 10;
      this.screenW = display.getDefaultDisplaySync().width / den;
      this.screenH = display.getDefaultDisplaySync().height / den;
    } catch (_e) {
      this.topPad = 48;
      this.botPad = 28;
    }
  }

  aboutToDisappear(): void {
    this.savePos();
    this.stopBg();
    if (this.session !== undefined) {
      try {
        this.session.deactivate();
        this.session.destroy();
      } catch (_e) {
      }
      this.session = undefined;
    }
    if (this.av !== undefined) {
      try {
        this.av.release();
      } catch (_e) {
      }
      this.av = undefined;
    }
    if (this.localPlaybackFd >= 0) {
      try { fileIo.closeSync(this.localPlaybackFd); } catch (_e) {}
      this.localPlaybackFd = -1;
    }
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
    if (this.similarQueryHintHandle >= 0) {
      clearTimeout(this.similarQueryHintHandle);
      this.similarQueryHintHandle = -1;
    }
    this.similarQueryHintVisible = false;
  }

  // 只负责从当前已选择的音乐源读取快照（NAS / 网盘 / 合并）。
  // 这个函数严禁读取/修改主题偏好、uiTheme、isDark 或系统栏，
  // 使“服务器数据刷新”和“外观主题刷新”成为两条完全独立的状态链。
  async reloadServerSnapshot(): Promise<void> {
    const sourceRows = await this.client.sources();
    this.sources = sourceRows;
    let selected = 0;
    let online = 0;
    for (let i = 0; i < sourceRows.length; i++) {
      if (this.sourceAllowed(sourceRows[i])) {
        selected++;
        if (sourceRows[i].online) online++;
      }
    }

    // 配置仍在但当前选中的音乐源全部离线：不要把“空请求结果”当成一次成功同步，
    // 更不能覆盖之前的收藏/歌单缓存。首页只保留真正的本地歌曲。
    if (selected === 0 || online === 0) {
      this.newest = [];
      this.recent = [];
      this.songs = [];
      this.albums = [];
      this.artists = [];
      this.playlists = [];
      this.liked = [];
      await this.loadPlaylistCache();
      await this.mergeOfflineMetadataSnapshot();
      this.applyPlaylistCacheState();
      AppStorage.setOrCreate('lumenOfflineHint', '无音乐来源');
      this.err = '';
      this.scanLocalLibrary();
      this.expandSavedQueue();
      return;
    }

    const soft = (p: Promise<void>): Promise<void> => p.catch((_e: Object) => {});
    await Promise.all([
      this.client.home().then((h: HomeData) => {
        this.newest = h.newest;
        this.recent = h.recent;
      }),
      soft(this.client.songs().then((v: Track[]) => { this.songs = v; })),
      soft(this.client.albums().then((v: Album[]) => { this.albums = v; })),
      soft(this.client.artists().then((v: Artist[]) => { this.artists = v; })),
      soft(this.client.playlists().then((v: Playlist[]) => { this.playlists = v; })),
      soft(this.client.liked().then((v: Track[]) => { this.liked = v; }))
    ]);
    await this.loadPlaylistCache();
    await this.refreshRemotePlaylistCaches();
    await this.mergeOfflineMetadataSnapshot();
    this.syncNasFavoriteCacheFromServer();
    this.upsertSongIndexFromTracks(this.songs);
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
    AppStorage.setOrCreate('lumenOfflineHint', '');
    this.err = '';
    await this.saveMetadataSnapshot();
    this.scanLocalLibrary();
    this.expandSavedQueue();
  }

  // 启动流程只在应用进入时执行：加载播放偏好与音乐源配置，随后读取一次服务器快照。
  // 主题由 aboutToAppear() 中单独的 loadThemePref() 负责。
  async boot(): Promise<void> {
    await this.loadAdvancedPrefs();
    const ctx0 = this.hostContext();
    this.buildLabel = BUILD_LABEL;
    try {
      const pf = await preferences.getPreferences(ctx0, 'lumen');
      this.audioFx = '' + (await pf.get('audioFx', '1')) !== '0';
      const sourceMode = Number(await pf.get('musicSourceMode', '2'));
      this.musicSourceMode = sourceMode >= 0 && sourceMode <= 2 ? sourceMode : 2;
    } catch (_e) {
      this.musicSourceMode = 2;
    }
    const cfgs = await MusicSourceManager.loadSourceCfgs(ctx0);
    this.client.setSourceMode(this.musicSourceMode);
    this.client.setSources(cfgs);
    this.sources = [];
    if (cfgs.length === 0) {
      await this.loadPlaylistCache();
      this.applyPlaylistCacheState();
      this.err = '还没有音乐源，去「我的 → 设置 → 音乐源」添加 NAS 或网盘';
      this.expandSavedQueue();
      return;
    }
    try {
      await this.reloadServerSnapshot();
    } catch (e) {
      const cached = await this.loadMetadataSnapshot();
      this.err = cached ? '音乐源暂时不可用，已显示元数据缓存' : ('' + e);
      this.expandSavedQueue();
    }
  }

  async refreshHomeFromServer(): Promise<void> {
    if (this.homeRefreshRunning) {
      return;
    }
    this.homeRefreshRunning = true;
    this.homeRefreshing = true;

    // 下拉刷新不会触发 NAS 扫描：Navidrome 只重新查询现有索引；
    // 网盘则清空本地目录索引并重新通过 WebDAV 询问远端目录。
    const beforeIds: string[] = [];
    for (let i = 0; i < this.songs.length; i++) {
      beforeIds.push(this.songs[i].source + '/' + this.songs[i].id);
    }

    this.setToast('正在向音乐源检查新歌…');
    this.client.invalidateCloud();
    try {
      const sourceRows = await this.client.sources();
      let online = 0;
      let selected = 0;
      for (let i = 0; i < sourceRows.length; i++) {
        const allowed = this.musicSourceMode === 2 ||
          (this.musicSourceMode === 0 && sourceRows[i].type === 'subsonic') ||
          (this.musicSourceMode === 1 && sourceRows[i].type === 'webdav');
        if (allowed) {
          selected++;
          if (sourceRows[i].online) {
            online++;
          }
        }
      }
      if (selected > 0 && online === 0) {
        throw new Error('当前选择的音乐源均无法连接');
      }

      // 下拉刷新只读服务器当前快照，不走 boot()，避免重新读取本地偏好或触发任何外观初始化。
      await this.reloadServerSnapshot();

      let added = 0;
      for (let i = 0; i < this.songs.length; i++) {
        const key = this.songs[i].source + '/' + this.songs[i].id;
        if (beforeIds.indexOf(key) < 0) {
          added++;
        }
      }
      if (added > 0) {
        this.setToast('刷新完成 · 发现 ' + added + ' 首新歌', 2000);
      } else {
        this.setToast('刷新完成 · 暂未发现新歌', 2000);
      }
    } catch (e) {
      this.setToast('刷新失败：' + errText(e as Object));
    } finally {
      this.homeRefreshing = false;
      this.homeRefreshRunning = false;
    }
  }

  async restoreState(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      const enabled = '' + (await p.get('continueLast', '0')) === '1';
      if (!enabled) {
        return;
      }
      const raw = '' + (await p.get('lastTrack', ''));
      if (raw.length === 0) {
        return;
      }
      const t = JSON.parse(raw) as Track;
      this.queue = [t];
      this.qpos = 0;
      this.nowTitle = t.title;
      this.nowArtist = t.artist;
      this.nowCover = this.client.abs(t.cover);
      this.nowLiked = t.liked;
      this.pullMood(this.nowCover, false);
      const pos = Number(await p.get('lastPos', '0'));
      if (pos > 1) {
        this.pendingSeek = pos;
      }
      const qraw = '' + (await p.get('lastQueue', ''));
      if (qraw.length > 0 && qraw.startsWith('[')) {
        this.savedQueueIds = JSON.parse(qraw) as SavedId[];
      }
    } catch (_e) {
    } finally {
      // HDS 首次挂载必须等上次播放元数据恢复完，否则 miniBar 会缓存占位状态。
      this.hdsPlaybackReady = true;
    }
  }

  expandSavedQueue(): void {
    this.nowPage = 0;
    if (this.songs.length === 0) {
      return;
    }
    const curNow = this.queue.length > 0 ? this.queue[this.qpos] : undefined;
    if (curNow !== undefined) {
      for (let i = 0; i < this.songs.length; i++) {
        if (this.songs[i].source === curNow.source && this.songs[i].id === curNow.id) {
          this.queue[this.qpos] = this.songs[i];
          this.nowTitle = this.songs[i].title;
          this.nowArtist = this.songs[i].artist;
          this.nowCover = this.client.abs(this.songs[i].cover);
          this.nowLiked = this.songs[i].liked;
          this.pullMood(this.nowCover, false);
          break;
        }
      }
    }
    if (this.savedQueueIds.length === 0) {
      return;
    }
    const q: Track[] = [];
    for (let i = 0; i < this.savedQueueIds.length; i++) {
      const sid = this.savedQueueIds[i];
      for (let j = 0; j < this.songs.length; j++) {
        if (this.songs[j].source === sid.source && this.songs[j].id === sid.id) {
          q.push(this.songs[j]);
          break;
        }
      }
    }
    if (q.length === 0) {
      return;
    }
    const cur = this.queue.length > 0 ? this.queue[this.qpos] : undefined;
    this.queue = q;
    this.qpos = 0;
    if (cur !== undefined) {
      for (let i = 0; i < q.length; i++) {
        if (q[i].source === cur.source && q[i].id === cur.id) {
          this.qpos = i;
          this.nowTitle = q[i].title;
          this.nowArtist = q[i].artist;
          this.nowCover = this.client.abs(q[i].cover);
          this.nowLiked = q[i].liked;
          this.pullMood(this.nowCover, false);
          break;
        }
      }
    }
  }

  async saveQueueState(): Promise<void> {
    try {
      const t = this.current();
      if (t === undefined) {
        return;
      }
      const trackKey = t.source + '/' + t.id;
      this.savePosKey = trackKey;
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      const ids: SavedId[] = [];
      for (let i = 0; i < this.queue.length && i < 300; i++) {
        ids.push({ source: this.queue[i].source, id: this.queue[i].id });
      }
      await p.put('lastTrack', JSON.stringify(t));
      await p.put('lastQueue', JSON.stringify(ids));
      await p.put('lastQpos', this.qpos);
      await p.put('lastPos', 0);
      await p.flush();
    } catch (_e) {
    }
  }

  async savePos(): Promise<void> {
    try {
      if (this.av === undefined || this.queue.length === 0) {
        return;
      }
      const t = this.current();
      if (t === undefined || this.savePosKey !== t.source + '/' + t.id) {
        return;
      }
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      await p.put('lastPos', this.pos);
      await p.flush();
    } catch (_e) {
    }
  }

  isLandscape(): boolean {
    return this.screenW > this.screenH;
  }

  wide(): boolean {
    try {
      const d = display.getDefaultDisplaySync();
      const den = d.densityPixels > 0 ? d.densityPixels : 3;
      return d.width / den >= 600;
    } catch (_e) {
      return false;
    }
  }

  cols(): string {
    return this.wide() ? '1fr 1fr 1fr 1fr' : '1fr 1fr';
  }

  qLabel(): string {
    return Q_NAME[this.qIndex];
  }

  current(): Track | undefined {
    if (this.qpos < 0 || this.qpos >= this.queue.length) {
      return undefined;
    }
    return this.queue[this.qpos];
  }

  isCurrentTrack(t: Track): boolean {
    const cur = this.current();
    if (cur === undefined) return false;
    if (cur.source === t.source && cur.id.length > 0 && t.id.length > 0) return cur.id === t.id;
    return cur.source === t.source && this.cacheNorm(cur.title) === this.cacheNorm(t.title) &&
      this.cacheNorm(cur.artist) === this.cacheNorm(t.artist);
  }

  async playList(list: Track[], index: number): Promise<void> {
    if (list.length === 0) {
      return;
    }
    if (index < 0 || index >= list.length || list[index].available === false) {
      this.setToast(CLOUD_OFFLINE_MESSAGE);
      return;
    }
    const selected = list[index];
    const playable: Track[] = [];
    let nextIndex = 0;
    for (let i = 0; i < list.length; i++) {
      const preferred = this.preferLocalTrack(list[i]);
      if (preferred.available !== false) {
        if (list[i].source === selected.source && list[i].id === selected.id) {
          nextIndex = playable.length;
        }
        playable.push(preferred);
      }
    }
    this.queue = playable;
    this.qpos = nextIndex;
    await this.playCurrent();
  }

  async playCurrent(): Promise<void> {
    const t = this.current();
    if (t === undefined) {
      return;
    }
    if (t.available === false) {
      this.playing = false;
      this.setToast(CLOUD_OFFLINE_MESSAGE);
      return;
    }
    this.nowTitle = t.title;
    this.nowArtist = t.artist;
    this.nowCover = this.client.abs(t.cover);
    this.nowLiked = t.liked;
    this.pullMood(this.nowCover, false);
    this.lyLines = [];
    this.lyIndex = 0;
    const nextScrobbleKey = t.source + '/' + t.id;
    if (this.scrobbleKey !== nextScrobbleKey || this.pendingSeek <= 0.25) {
      this.pos = 0;
      this.scrobbleKey = nextScrobbleKey;
      this.scrobbleSubmitted = false;
      this.statRecordedKey = '';
      this.client.scrobble(t, false).catch(() => {});
    }
    const access = this.client.streamAccess(t, Q_BR[this.qIndex]);
    this.saveQueueState();
    this.ensureSession();
    this.updateSessionMeta(t);
    try {
      if (this.av !== undefined) {
        await this.av.release();
        this.av = undefined;
      }
      if (this.localPlaybackFd >= 0) {
        try { fileIo.closeSync(this.localPlaybackFd); } catch (_e) {}
        this.localPlaybackFd = -1;
      }
      const player: media.AVPlayer = await media.createAVPlayer();
      this.av = player;
      this.applyInterruptMode(player);
      try {
        player.audioEffectMode = this.audioFx
          ? audio.AudioEffectMode.EFFECT_DEFAULT
          : audio.AudioEffectMode.EFFECT_NONE;
      } catch (_fx) {
      }
      player.on('stateChange', (st: string) => {
        if (st === 'initialized') {
          player.prepare();
        } else if (st === 'prepared') {
          this.applyInterruptMode(player);
          const gainDb = t.replayGainDb !== undefined ? t.replayGainDb : 0;
          if (this.replayGain && Math.abs(gainDb) > 0.01) {
            try { (player as LoudnessPlayer).setLoudnessGain(gainDb); } catch (_gain) {}
          }
          if (this.fadeAudio) { try { player.setVolume(0); } catch (_vol) {} }
          player.play();
          this.beginFadeIn(player);
          this.dur = player.duration > 0 ? player.duration / 1000 : t.duration;
          this.updateSessionMeta(t);
          this.updateSessionState();
        } else if (st === 'completed') {
          if (!this.scrobbleSubmitted && this.scrobbleKey === t.source + '/' + t.id) {
            this.scrobbleSubmitted = true;
            this.recordStatPlay(t);
            this.client.scrobble(t, true).catch(() => {});
          }
          this.next(false);
        } else if (st === 'playing') {
          this.playing = true;
          if (this.pendingSeek > 0.25) {
            const s = this.pendingSeek;
            this.pendingSeek = -1;
            // Wait until the network/transcoded stream is really playing before restoring position.
            setTimeout(() => { this.seekTo(s); }, 260);
          }
        } else if (st === 'paused' || st === 'stopped') {
          this.playing = false;
        }
      });
      player.on('error', (error: BusinessError) => {
        this.playing = false;
        const quality = this.qIndex >= 0 && this.qIndex < Q_NAME.length ? Q_NAME[this.qIndex] : '未知音质';
        const msg = '播放失败（' + quality + '）：' + error.code + ' ' + error.message;
        this.err = msg;
        this.setToast(msg, 3200);
        this.updateSessionState();
      });
      if (this.client.sourceType(t.source) === 'local') {
        const localFile = fileIo.openSync(t.stream, fileIo.OpenMode.READ_ONLY);
        const st = fileIo.statSync(t.stream);
        this.localPlaybackFd = localFile.fd;
        const fdSrc: media.AVFileDescriptor = { fd: localFile.fd, offset: 0, length: st.size };
        player.fdSrc = fdSrc;
      } else if (access.hasHeaders || this.client.sourceType(t.source) === 'subsonic') {
        // Use MediaSource for Navidrome/Subsonic as well. It handles buffered network/transcoded
        // streams more reliably than assigning AVPlayer.url directly.
        const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(access.url, access.headers);
        const strategy: media.PlaybackStrategy = { preferredBufferDuration: 20 };
        player.setMediaSource(mediaSource, strategy);
      } else {
        player.url = access.url;
      }
      this.loadLyrics(t);
    } catch (e) {
      this.err = '' + e;
    }
  }

  loadLocalLyrics(t: Track): LyricLine[] {
    const dot = t.stream.lastIndexOf('.');
    if (dot < 0) return [];
    const path = t.stream.substring(0, dot) + '.lrc';
    try {
      if (!fileIo.accessSync(path)) return [];
      const st = fileIo.statSync(path);
      if (st.size <= 0 || st.size > 2 * 1024 * 1024) return [];
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const data = new ArrayBuffer(st.size);
      const read = fileIo.readSync(f.fd, data);
      fileIo.closeSync(f);
      const text = buffer.from(data, 0, read).toString();
      const out: LyricLine[] = [];
      const rows = text.replace(/\r/g, '').split('\n');
      const re = /\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\]/g;
      for (let i = 0; i < rows.length; i++) {
        const raw = rows[i];
        let m = re.exec(raw);
        while (m !== null) {
          const frac = m[3] !== undefined ? Number('0.' + m[3]) : 0;
          const sec = Number(m[1]) * 60 + Number(m[2]) + frac;
          const line = raw.replace(/\[[^\]]+\]/g, '').trim();
          if (line.length > 0) out.push({ t: sec, line: line });
          m = re.exec(raw);
        }
        re.lastIndex = 0;
      }
      out.sort((a: LyricLine, b: LyricLine) => a.t - b.t);
      return out;
    } catch (_e) {
      return [];
    }
  }

  async loadLyrics(t: Track): Promise<void> {
    this.lyricsStatus = '歌词加载中…';
    try {
      if (this.client.sourceType(t.source) === 'local') {
        this.lyLines = this.loadLocalLyrics(t);
      } else if (t.suffix === 'radio') {
        this.lyLines = [];
      } else {
        this.lyLines = await this.client.songLyrics(t.source, t);
      }
      this.lyricsStatus = this.lyLines.length > 0 ? ('歌词 ' + this.lyLines.length + ' 行') : '服务器里这首歌没有歌词';
    } catch (_e) {
      this.lyLines = [];
      this.lyricsStatus = '歌词加载失败';
    }
  }

  startWavePulse(): void {
    if (this.waveAnimating) return;
    this.waveAnimating = true;
    try {
      this.getUIContext().animateTo({
        duration: 920, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
      }, () => {
        this.wavePulse = 1;
      });
    } catch (_e) {
      this.wavePulse = 1;
    }
  }

  startOrbs(): void {
    if (this.orbsRunning) {
      return;
    }
    this.orbsRunning = true;
    this.getUIContext().animateTo({
      duration: 18000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.orbA = 1;
    });
    this.getUIContext().animateTo({
      duration: 21000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.orbB = 1;
    });
    this.getUIContext().animateTo({
      duration: 24000, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate
    }, () => {
      this.orbC = 1;
    });
  }

  stopOrbs(): void {
    if (!this.orbsRunning) {
      return;
    }
    this.orbsRunning = false;
    this.getUIContext().animateTo({ duration: 1400, curve: Curve.EaseOut }, () => {
      this.orbA = 0;
      this.orbB = 0;
      this.orbC = 0;
    });
  }

  async startBg(): Promise<void> {
    if (this.bgActive) {
      return;
    }
    try {
      const ctx = this.hostContext();
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'app.meow.music', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      } as wantAgent.WantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(ctx, ['audioPlayback'], agent);
      this.bgActive = true;
    } catch (_e) {
      this.bgActive = false;
    }
  }

  async stopBg(): Promise<void> {
    if (!this.bgActive) {
      return;
    }
    try {
      const ctx = this.hostContext();
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (_e) {
    }
    this.bgActive = false;
  }

  ensureSession(): void {
    if (this.session !== undefined) {
      return;
    }
    try {
      const ctx = this.hostContext();
      AVSessionManager.createAVSession(ctx, 'meow-playback', 'audio')
        .then((session: AVSessionManager.AVSession) => {
          session.on('play', () => {
            if (!this.playing) {
              this.toggle();
              this.updateSessionState();
            }
          });
          session.on('pause', () => {
            if (this.playing) {
              this.toggle();
              this.updateSessionState();
            }
          });
          session.on('playNext', () => {
            this.next(true);
          });
          session.on('playPrevious', () => {
            this.prev();
          });
          session.on('toggleFavorite', (assetId: string) => {
            const t = this.current();
            if (t !== undefined && (t.source + '/' + t.id) === assetId) {
              this.likeTrack(t);
            }
          });
          session.on('seek', (time: number) => {
            this.seekTo(time / 1000);
          });
          session.on('setLoopMode', (mode: AVSessionManager.LoopMode) => {
            this.applySystemLoopMode(mode);
          });
          session.on('setTargetLoopMode', (mode: AVSessionManager.LoopMode) => {
            this.applySystemLoopMode(mode);
          });
          try {
            session.setSupportedLoopModes([
              AVSessionManager.LoopMode.LOOP_MODE_SEQUENCE,
              AVSessionManager.LoopMode.LOOP_MODE_SINGLE,
              AVSessionManager.LoopMode.LOOP_MODE_LIST,
              AVSessionManager.LoopMode.LOOP_MODE_SHUFFLE
            ]).catch((_e: Object) => {});
          } catch (_e) {
          }
          session.activate();
          this.session = session;
          this.updateSessionState();
          this.lvSync();
        });
    } catch (_e) {
    }
  }

  updateSessionMeta(t: Track): void {
    if (this.session === undefined) {
      return;
    }
    try {
      const meta: AVSessionManager.AVMetadata = {
        assetId: t.source + '/' + t.id,
        title: t.title,
        artist: t.artist,
        mediaImage: this.nowCover,
        duration: Math.floor(this.dur * 1000)
      };
      this.session.setAVMetadata(meta);
    } catch (_e) {
    }
  }

  updateSessionLyric(): void {
    if (!this.carLyrics || this.session === undefined || this.lyIndex < 0 || this.lyIndex >= this.lyLines.length) return;
    const t = this.current();
    if (t === undefined) return;
    try {
      const meta: AVSessionManager.AVMetadata = {
        assetId: t.source + '/' + t.id,
        title: this.lyLines[this.lyIndex].line,
        artist: t.title + ' · ' + t.artist,
        mediaImage: this.nowCover,
        duration: Math.floor(this.dur * 1000)
      };
      this.session.setAVMetadata(meta);
    } catch (_e) {
    }
  }

  async lvSync(): Promise<void> {
    this.lvState = this.lvActive ? '实况窗：已激活' : '实况窗：未激活';
    const t = this.current();
    if (t === undefined || this.dur <= 0) {
      return;
    }
    try {
      const click = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'app.meow.music', abilityName: 'EntryAbility' }]
      } as wantAgent.WantAgentInfo);
      const lv: liveViewManager.LiveView = {
        id: this.lvId,
        event: 'lumen-music',
        liveViewData: {
          primary: {
            title: t.title,
            content: [{ text: t.artist }],
            clickAction: click
          },
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_PROGRESS,
            status: this.playing ? 1 : 2,
            max: Math.max(1, Math.floor(this.dur)),
            progress: Math.max(0, Math.floor(this.pos)),
            content: fmtDur(this.pos) + ' / ' + fmtDur(this.dur)
          }
        }
      };
      if (this.lvActive) {
        await liveViewManager.updateLiveView(lv);
      } else {
        const r = await liveViewManager.startLiveView(lv);
        this.lvActive = r !== undefined && r.resultCode === 0;
      }
    } catch (_e) {
    }
  }

  async lvStop(): Promise<void> {
    if (!this.lvActive) {
      return;
    }
    try {
      await liveViewManager.stopLiveView({
        id: this.lvId,
        event: 'lumen-music',
        liveViewData: {
          primary: {
            title: '',
            content: [{ text: '' }]
          }
        }
      });
    } catch (_e) {
    }
    this.lvActive = false;
  }

  systemLoopMode(): AVSessionManager.LoopMode {
    if (this.repeat === 2) return AVSessionManager.LoopMode.LOOP_MODE_SINGLE;
    if (this.repeat === 1) return AVSessionManager.LoopMode.LOOP_MODE_LIST;
    if (this.repeat === 0) return AVSessionManager.LoopMode.LOOP_MODE_SHUFFLE;
    return AVSessionManager.LoopMode.LOOP_MODE_SEQUENCE;
  }

  applySystemLoopMode(mode: AVSessionManager.LoopMode): void {
    if (mode === AVSessionManager.LoopMode.LOOP_MODE_SINGLE) {
      this.repeat = 2;
    } else if (mode === AVSessionManager.LoopMode.LOOP_MODE_LIST) {
      this.repeat = 1;
    } else if (mode === AVSessionManager.LoopMode.LOOP_MODE_SHUFFLE) {
      this.repeat = 0;
    } else {
      this.repeat = 3;
    }
    this.updateSessionState();
    this.lvSync();
  }

  updateSessionState(): void {
    if (this.session === undefined) {
      return;
    }
    try {
      const st: AVSessionManager.AVPlaybackState = {
        state: this.playing ? AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY
          : AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: 1.0,
        position: { elapsedTime: Math.floor(this.pos * 1000), updateTime: Date.now() },
        duration: Math.floor(this.dur * 1000),
        isFavorite: this.nowLiked,
        loopMode: this.systemLoopMode()
      };
      this.session.setAVPlaybackState(st);
    } catch (_e) {
    }
  }

  tick(): void {
    // 跟随系统主题时也保持实时同步，不依赖重新进入页面触发重建。
    this.refreshFollowSystemTheme();
    this.maybeRefreshAppIcon();
    if (this.toast.length > 0 && Date.now() - this.toastAt > this.toastDurationMs) {
      this.toast = '';
    }
    if (this.playing !== this.sessPlaying) {
      this.sessPlaying = this.playing;
      this.updateSessionState();
    }
    if (this.playing && !this.bgActive) {
      this.startBg();
    }
    if (!this.playing && this.bgActive && this.queue.length === 0) {
      this.stopBg();
    }
    const p = this.av;
    if (p === undefined) {
      return;
    }
    this.tickN++;
    this.recordListeningTick();
    if (this.tickN % 15 === 0 && this.playing) {
      this.savePos();
    }
    if (this.playing) {
      this.miniCoverAngle = this.miniCoverAngle + 8;
      this.lvTick++;
      if (this.lvTick % 5 === 0) {
        this.lvSync();
      }
    }
    try {
      const t = p.currentTime;
      if (t >= 0) {
        const newPos = t / 1000;
        if (Math.abs(newPos - this.pos) > 0.3) {
          this.pos = newPos;
        }
      }
    } catch (_e) {
    }
    if (this.playing) {
      this.maybeScrobble();
    }
    let idx = 0;
    for (let i = 0; i < this.lyLines.length; i++) {
      if (this.lyLines[i].t <= this.pos) {
        idx = i;
      }
    }
    if (idx !== this.lyIndex) {
      this.lyIndex = idx;
      this.updateSessionLyric();
      try {
        this.lyricScroller.scrollToIndex(idx + 1, true, ScrollAlign.CENTER);
      } catch (_e) {
      }
    }
    if (this.nowOpen && this.nowPage === 1 && this.playing) {
      const since = Date.now() - this.idleAt;
      if (since > 5000 && this.idleK < 0.01) {
        this.getUIContext().animateTo({
          duration: 420,
          curve: curves.interpolatingSpring(0, 1, 363, 38)
        }, () => {
          this.idleK = 1;
        });
      }
    } else if (this.idleK > 0) {
      this.idleK = 0;
    }
  }

  maybeScrobble(): void {
    const t = this.current();
    if (t === undefined || this.scrobbleSubmitted || this.scrobbleKey !== t.source + '/' + t.id) {
      return;
    }
    const total = this.dur > 0 ? this.dur : t.duration;
    const threshold = total > 0 ? Math.min(240, Math.max(30, total * 0.5)) : 240;
    if (this.pos < threshold) {
      return;
    }
    this.scrobbleSubmitted = true;
    this.recordStatPlay(t);
    this.client.scrobble(t, true).catch(() => {
      this.scrobbleSubmitted = false;
    });
  }

  resetIdle(): void {
    this.idleAt = Date.now();
    if (this.idleK > 0.01) {
      this.getUIContext().animateTo({
        duration: 360,
        curve: curves.interpolatingSpring(0, 1, 363, 38)
      }, () => {
        this.idleK = 0;
      });
    }
  }

  async seekTo(sec: number): Promise<void> {
    const p = this.av;
    if (p === undefined) {
      return;
    }
    const ms = Math.floor(sec * 1000);
    try {
      p.seek(ms, media.SeekMode.SEEK_PREV_SYNC);
    } catch (_e) {
      try {
        p.seek(ms);
      } catch (_e2) {
      }
    }
    this.pos = sec;
    this.updateSessionState();
  }

  runMotion(fn: () => void, ms: number = 520, snap?: () => void, curve?: Curve | ICurve | string): void {
    this.getUIContext().animateTo({
      duration: ms,
      curve: curve !== undefined ? curve : Curve.Friction,
      onFinish: () => {
        if (snap !== undefined) {
          snap();
        }
      }
    }, fn);
  }

  openNow(): void {
    this.nowPage = 0;
    this.queueOpen = false;
    this.playerTargetOpen = true;
    const token = ++this.playerMotionToken;
    this.nowOpen = true;
    this.applySysBar();
    this.runMotion(() => {
      this.expand = 1;
    }, 420, () => {
      if (token === this.playerMotionToken && this.playerTargetOpen) {
        this.expand = 1;
        this.nowOpen = true;
      }
    }, curves.interpolatingSpring(0, 1, 363, 38));
    // animateTo 被返回手势/其它动画打断时仍要收敛到明确状态，避免停在半展开卡片。
    setTimeout(() => {
      if (token === this.playerMotionToken && this.playerTargetOpen && this.expand > 0.96) {
        this.expand = 1;
        this.nowOpen = true;
      }
    }, 760);
  }

  closeNow(): void {
    this.queueOpen = false;
    this.playerTargetOpen = false;
    const token = ++this.playerMotionToken;
    // 关闭动画结束前保留 nowOpen=true。这样即便动画被中断，下一次返回仍会继续关闭，
    // 不会出现 expand 处在 0~1 之间但逻辑已经认为播放器关闭的死状态。
    this.nowOpen = true;
    this.runMotion(() => {
      this.expand = 0;
    }, 380, () => {
      if (token === this.playerMotionToken && !this.playerTargetOpen) {
        this.expand = 0;
        this.nowOpen = false;
        this.applySysBar();
      }
    }, curves.interpolatingSpring(0, 1, 363, 38));
    // 兜底收敛：系统返回动画、连续手势等中断 ArkUI 动画时也不会卡在半屏。
    setTimeout(() => {
      if (token === this.playerMotionToken && !this.playerTargetOpen) {
        this.expand = 0;
        this.nowOpen = false;
        this.applySysBar();
      }
    }, 620);
  }

  goBack(): boolean {
    if (this.detailNavStack.getAllPathName().length > 0) {
      this.closeDetailRoute();
      return true;
    }
    if (this.settingPickerOpen) {
      this.settingPickerOpen = false;
      return true;
    }
    if (this.plPickOn || this.manageOpen || this.plDlgMode > 0 || this.importOpen) {
      this.plPickOn = false;
      this.manageOpen = false;
      this.plDlgMode = 0;
      this.importOpen = false;
      return true;
    }
    if (this.page === 'advanced' || this.page === 'icons') {
      this.openSettingsPage();
      return true;
    }
    if (this.page === 'stats') {
      this.page = 'main';
      this.tab = 3;
      return true;
    }
    if (this.page === 'local' || this.page === 'downloads' || this.page === 'liked' || this.page === 'recent' || this.page === 'followed') {
      this.page = 'main';
      this.tab = 3;
      return true;
    }
    if (this.page === 'settings') {
      this.page = 'main';
      return true;
    }
    if (this.qualityOpen) {
      this.qualityOpen = false;
      return true;
    }
    if (this.sleepPickerOpen) {
      this.sleepPickerOpen = false;
      return true;
    }
    if (this.moreOpen) {
      this.moreOpen = false;
      return true;
    }
    if (this.queueOpen) {
      this.queueOpen = false;
      return true;
    }
    if (this.nowOpen || this.expand > 0.02) {
      this.closeNow();
      return true;
    }
    return false;
  }

  onBackPress(): boolean {
    return this.goBack();
  }

  onSheetPan(y: number, ended: boolean): void {
    if (!ended) {
      this.playerTargetOpen = true;
      this.nowOpen = true;
      const d = y < 0 ? 0 : y;
      this.expand = Math.max(0, 1 - d / this.screenH);
      return;
    }
    if (y > this.screenH * 0.18) {
      this.closeNow();
    } else {
      this.playerTargetOpen = true;
      const token = ++this.playerMotionToken;
      this.runMotion(() => {
        this.expand = 1;
        this.nowOpen = true;
      }, 420, () => {
        if (token === this.playerMotionToken && this.playerTargetOpen) {
          this.expand = 1;
          this.nowOpen = true;
        }
      }, curves.cubicBezierCurve(0.16, 1, 0.3, 1));
    }
  }

  onQueuePan(y: number, ended: boolean): void {
    if (!ended) {
      this.queueDrag = y < 0 ? 0 : y;
      return;
    }
    if (y > 90) {
      this.queueOpen = false;
      this.queueDrag = 0;
    } else {
      this.runMotion(() => {
        this.queueDrag = 0;
      }, 280);
    }
  }

  async tapHeroPlay(a: Album): Promise<void> {
    try {
      const full = await this.client.album(a.source, a.id);
      const tracks = full.tracks !== undefined ? full.tracks : [];
      if (tracks.length > 0) {
        await this.playList(tracks, 0);
      }
    } catch (e) {
      this.err = '' + e;
    }
  }

  switchTab(n: number): void {
    if (n === this.tab && this.page === 'main') {
      return;
    }
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
      this.stageFade = 0.88;
    });
    setTimeout(() => {
      this.tab = n;
      this.page = 'main';
      if (n === 1) {
        this.loadLib(this.lib);
      }
      if (n === 3) {
        this.loadMe();
      }
      this.getUIContext().animateTo({ duration: 420, curve: curves.cubicBezierCurve(0.16, 1, 0.3, 1) }, () => {
        this.stageFade = 1;
      });
    }, 80);
  }

  async toggle(): Promise<void> {
    if (this.av === undefined) {
      if (this.queue.length > 0) {
        await this.playCurrent();
      }
      return;
    }
    const p = this.av;
    let st = '';
    try {
      st = '' + p.state;
    } catch (_e) {
    }
    try {
      if (st === 'playing' || this.playing) {
        await p.pause();
        this.playing = false;
      } else {
        await p.play();
        this.playing = true;
      }
      this.updateSessionState();
      if (this.playing) {
        this.lvSync();
      } else {
        this.lvTick = 0;
      }
    } catch (_e) {
    }
  }

  async next(fromUser: boolean): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (this.repeat === 2 && !fromUser) {
      await this.playCurrent();
      return;
    }
    if (this.repeat === 0) {
      let n = this.qpos;
      if (this.queue.length > 1) {
        while (n === this.qpos) {
          n = Math.floor(Math.random() * this.queue.length);
        }
      }
      this.qpos = n;
      await this.playCurrent();
      return;
    }
    const n = this.qpos + 1;
    if (n >= this.queue.length) {
      if (!fromUser && this.repeat === 3) {
        this.playing = false;
        this.updateSessionState();
        this.stopBg();
        this.lvStop();
        return;
      }
      this.qpos = 0;
    } else {
      this.qpos = n;
    }
    await this.playCurrent();
  }

  async prev(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    let n = this.qpos - 1;
    if (n < 0) {
      n = this.queue.length - 1;
    }
    this.qpos = n;
    await this.playCurrent();
  }

  async pickQuality(i: number): Promise<void> {
    this.qualityOpen = false;
    if (i === this.qIndex) {
      return;
    }
    this.pendingSeek = this.pos;
    this.qIndex = i;
    if (this.current() !== undefined) {
      await this.playCurrent();
    }
  }

  async openNowArtist(): Promise<void> {
    const t = this.current();
    this.moreOpen = false;
    if (t === undefined) return;
    let artistId = t.artistId;
    let artistCover = t.cover;
    if (artistId.length === 0) {
      const pools: Artist[][] = [this.artists, this.hitArtists, this.followedArtistRows()];
      for (let p = 0; p < pools.length && artistId.length === 0; p++) {
        for (let i = 0; i < pools[p].length; i++) {
          const row = pools[p][i];
          if (row.source === t.source && this.cacheNorm(row.name) === this.cacheNorm(t.artist)) {
            artistId = row.id;
            if (row.cover.length > 0) artistCover = row.cover;
            break;
          }
        }
      }
    }
    if (artistId.length === 0) {
      this.setToast('当前歌曲没有可用的艺人详情');
      return;
    }
    this.closeNow();
    const a: Artist = {
      id: artistId,
      source: t.source,
      name: t.artist,
      albumCount: 0,
      cover: artistCover
    };
    await this.openArtist(a);
  }

  async openNowAlbum(): Promise<void> {
    const t = this.current();
    this.moreOpen = false;
    if (t === undefined || t.albumId.length === 0) {
      return;
    }
    this.closeNow();
    const a: Album = {
      id: t.albumId,
      source: t.source,
      title: t.album,
      artist: t.artist,
      cover: t.cover,
      year: 0
    };
    await this.openAlbum(a);
  }

  setSleepMinutes(minutes: number): void {
    const safe = Math.max(0, Math.min(720, Math.floor(minutes)));
    if (this.sleepHandle >= 0) {
      clearTimeout(this.sleepHandle);
      this.sleepHandle = -1;
    }
    this.sleepMin = safe;
    this.sleepEndAt = safe > 0 ? Date.now() + safe * 60 * 1000 : 0;
    if (safe <= 0) {
      this.setToast('已取消定时关闭');
      return;
    }
    this.sleepHandle = setTimeout(() => {
      if (this.playing) this.toggle();
      this.sleepHandle = -1;
      this.sleepMin = 0;
      this.sleepEndAt = 0;
      this.setToast('定时结束，已暂停播放');
    }, safe * 60 * 1000);
    const end = new Date(this.sleepEndAt);
    const hh = ('0' + end.getHours()).slice(-2);
    const mm = ('0' + end.getMinutes()).slice(-2);
    this.setToast(safe + ' 分钟后暂停 · ' + hh + ':' + mm);
  }

  applyCustomSleep(): void {
    const min = Number(this.sleepCustomText);
    if (!Number.isFinite(min) || min < 1 || min > 720) {
      this.setToast('自定义时间请输入 1–720 分钟');
      return;
    }
    this.sleepPickerOpen = false;
    this.setSleepMinutes(min);
  }

  sleepLabel(): string {
    if (this.sleepEndAt <= Date.now() || this.sleepMin <= 0) return '定时关闭';
    const left = Math.max(1, Math.ceil((this.sleepEndAt - Date.now()) / 60000));
    return '定时关闭：剩余约 ' + left + ' 分钟';
  }

  async similarNow(): Promise<void> {
    if (this.similarQueryBusy) {
      return;
    }
    const t = this.current();
    if (t === undefined) {
      this.setToast('请先播放一首音乐');
      return;
    }

    // 查询开始后立即锁住入口；只有超过 1 秒仍未返回时，才在播放页封面下方显示“正在查询中…”。
    this.similarQueryBusy = true;
    this.similarQueryHintVisible = false;
    if (this.similarQueryHintHandle >= 0) {
      clearTimeout(this.similarQueryHintHandle);
      this.similarQueryHintHandle = -1;
    }
    this.similarQueryHintHandle = setTimeout(() => {
      this.similarQueryHintHandle = -1;
      if (this.similarQueryBusy) {
        this.similarQueryHintVisible = true;
      }
    }, 1000);

    try {
      const rows = await this.client.similarSongs(t, 50);
      const mix: Track[] = [t];
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].source !== t.source || rows[i].id !== t.id) {
          mix.push(rows[i]);
        }
      }
      if (mix.length <= 1) {
        this.setToast('暂无相关歌曲', 2200);
        return;
      }
      this.queue = mix;
      this.qpos = 0;
      this.saveQueueState();
      this.queueDrag = 0;
      this.queueOpen = true;
      this.setToast('已生成相似音乐队列 · ' + (mix.length - 1) + ' 首');
    } catch (e) {
      this.setToast('相似音乐不可用：' + errText(e as Object));
    } finally {
      if (this.similarQueryHintHandle >= 0) {
        clearTimeout(this.similarQueryHintHandle);
        this.similarQueryHintHandle = -1;
      }
      this.similarQueryHintVisible = false;
      this.similarQueryBusy = false;
    }
  }

  safeDownloadName(s: string): string {
    const v = s.replace(/[\\/:*?"<>|]/g, '_').trim();
    return v.length > 0 ? v : '觅乐';
  }

  downloadSuffix(t: Track): string {
    const raw = (t.suffix !== undefined ? t.suffix : '').trim().toLowerCase().replace(/[^a-z0-9]/g, '');
    return raw.length > 0 ? raw : 'mp3';
  }

  downloadTrackKey(t: Track): string {
    if (t.source.length > 0 && t.id.length > 0) return t.source + '\u001F' + t.id;
    return t.source + '\u001F' + this.cacheNorm(t.artist) + '\u001F' + this.cacheNorm(t.title);
  }

  downloadTargetPath(t: Track): string {
    const ext = this.downloadSuffix(t);
    const fileName = this.safeDownloadName(t.artist + ' - ' + t.title) + '.' + ext;
    return this.localDownloadDir() + '/' + fileName;
  }

  isTrackDownloading(t: Track): boolean {
    const key = this.downloadTrackKey(t);
    for (let i = 0; i < this.downloadingTrackKeys.length; i++) {
      if (this.downloadingTrackKeys[i] === key) return true;
    }
    return false;
  }

  setTrackDownloading(t: Track, active: boolean): void {
    const key = this.downloadTrackKey(t);
    const next: string[] = [];
    let found = false;
    for (let i = 0; i < this.downloadingTrackKeys.length; i++) {
      if (this.downloadingTrackKeys[i] === key) found = true; else next.push(this.downloadingTrackKeys[i]);
    }
    if (active && !found) next.push(key);
    this.downloadingTrackKeys = next;
    this.downloadUiSerial++;
  }

  isTrackDownloaded(t: Track): boolean {
    // 读取 serial 让下载完成/失败后立即触发播放页图标刷新；实际状态仍以持久文件为准。
    const _serial = this.downloadUiSerial;
    if (_serial < 0) return false;
    if (t.suffix === 'radio') return false;
    if (this.client.sourceType(t.source) === 'local') return true;
    if (this.client.sourceType(t.source) === 'webdav') return false;
    try {
      return fileIo.accessSync(this.downloadTargetPath(t));
    } catch (_e) {
      return false;
    }
  }

  currentDownloadState(): number {
    const t = this.current();
    if (t === undefined || t.suffix === 'radio') return 0;
    if (this.isTrackDownloading(t)) return 1;
    if (this.isTrackDownloaded(t)) return 2;
    return 0;
  }

  removeDownloadTask(task: request.agent.Task): void {
    const i = this.downloadTasks.indexOf(task);
    if (i >= 0) {
      this.downloadTasks.splice(i, 1);
    }
  }

  async downloadNow(): Promise<void> {
    const t = this.current();
    if (t === undefined) {
      this.setToast('请先播放一首音乐');
      return;
    }
    if (this.client.sourceType(t.source) === 'webdav') {
      this.setToast('网盘音源仅用于在线播放，不提供下载到手机');
      return;
    }
    if (this.client.sourceType(t.source) === 'local' || t.suffix === 'radio') {
      this.setToast(t.suffix === 'radio' ? '电台不支持下载' : '这首歌已经在本地曲库');
      return;
    }
    try {
      const ctx = this.hostContext();
      this.ensureLocalFolders();
      const targetPath = this.downloadTargetPath(t);

      // 同一首歌只保留一份：已下载或正在下载时都不再创建第二个任务。
      if (fileIo.accessSync(targetPath)) {
        this.downloadUiSerial++;
        this.setToast('已下载 · 可在本地音乐中播放：' + t.title);
        return;
      }
      if (this.isTrackDownloading(t)) {
        this.setToast('正在下载：' + t.title);
        return;
      }

      this.setTrackDownloading(t, true);
      const url = this.client.download(t);
      const config: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: url,
        overwrite: false,
        method: 'GET',
        saveas: targetPath,
        mode: request.agent.Mode.BACKGROUND,
        gauge: true,
        retry: true
      };
      this.setToast('开始下载到 Meow/download：' + t.title);
      request.agent.create(ctx, config).then((task: request.agent.Task) => {
        this.downloadTasks.push(task);
        task.on('completed', () => {
          this.removeDownloadTask(task);
          this.setTrackDownloading(t, false);
          this.scanLocalLibrary();
          this.setToast('下载完成 · 已加入本地曲库：' + t.title);
        });
        task.on('failed', () => {
          this.removeDownloadTask(task);
          this.setTrackDownloading(t, false);
          try { if (fileIo.accessSync(targetPath)) fileIo.unlinkSync(targetPath); } catch (_e) {}
          this.setToast('下载失败：' + t.title);
        });
        task.start((err: BusinessError) => {
          if (err) {
            this.removeDownloadTask(task);
            this.setTrackDownloading(t, false);
            try { if (fileIo.accessSync(targetPath)) fileIo.unlinkSync(targetPath); } catch (_e) {}
            this.setToast('下载启动失败：' + err.message);
          }
        });
      }).catch((e: Object) => {
        this.setTrackDownloading(t, false);
        try { if (fileIo.accessSync(targetPath)) fileIo.unlinkSync(targetPath); } catch (_e) {}
        this.setToast('下载任务创建失败：' + errText(e));
      });
    } catch (e) {
      this.setTrackDownloading(t, false);
      this.setToast('下载失败：' + errText(e as Object));
    }
  }

  async shareNow(): Promise<void> {
    const t = this.current();
    if (t === undefined) {
      this.setToast('请先播放一首音乐');
      return;
    }
    try {
      const text = t.title + ' — ' + t.artist;
      const data = new systemShare.SharedData({
        utd: utd.UniformDataType.TEXT,
        content: text,
        title: t.title,
        description: t.artist
      });
      const controller = new systemShare.ShareController(data);
      const ctx = this.hostContext();
      await controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      });
    } catch (e) {
      this.setToast('系统分享失败：' + errText(e as Object));
    }
  }

  async copyNow(): Promise<void> {
    this.moreOpen = false;
    const t = this.current();
    if (t === undefined) {
      return;
    }
    const text = t.title + ' — ' + t.artist;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.setToast('已复制「' + text + '」');
    } catch (e) {
      this.setToast('复制失败：' + errText(e as Object));
    }
  }

  goAddPlaylist(): void {
    this.moreOpen = false;
    this.closeNow();
    this.tab = 3;
    this.loadMe();
  }

  setTrackLikedEverywhere(t: Track, liked: boolean): void {
    t.liked = liked;
    const lists: Track[][] = [this.localSongs, this.songs, this.hitSongs, this.detailTracks, this.queue];
    for (let k = 0; k < lists.length; k++) {
      for (let i = 0; i < lists[k].length; i++) {
        const x = lists[k][i];
        if ((x.source === t.source && x.id === t.id) ||
          (this.cacheNorm(x.title) === this.cacheNorm(t.title) && this.cacheNorm(x.artist) === this.cacheNorm(t.artist))) {
          x.liked = liked;
        }
      }
    }
    const cur = this.current();
    if (cur !== undefined && ((cur.source === t.source && cur.id === t.id) ||
      (this.cacheNorm(cur.title) === this.cacheNorm(t.title) && this.cacheNorm(cur.artist) === this.cacheNorm(t.artist)))) {
      cur.liked = liked;
      this.nowLiked = liked;
      this.updateSessionState();
    }
    this.localSongs = this.localSongs.slice();
    this.songs = this.songs.slice();
    this.hitSongs = this.hitSongs.slice();
    this.detailTracks = this.detailTracks.slice();
    this.queue = this.queue.slice();
  }

  async likeTrack(t: Track): Promise<void> {
    if (t.suffix === 'radio') {
      this.setToast('电台不支持收藏');
      return;
    }
    const type = this.client.sourceType(t.source);
    const next = !this.isCachedFavorite(this.trackRef(t));
    this.setTrackLikedEverywhere(t, next);

    // 所有收藏动作先落本地。即使此刻 NAS 断线，用户的操作也绝不会丢。
    await this.setCloudFavorite(t, next);

    if (type === 'webdav') {
      this.setToast(next ? '已本地收藏' : '已取消收藏');
      return;
    }

    await this.enqueuePendingFavoriteOp(t, next);
    if (type === 'local') {
      if (this.hasOnlineMusicSource()) {
        await this.syncPendingFavoriteOps();
        this.setToast(next ? '已收藏 · 正在尝试匹配 NAS' : '已取消收藏 · 正在同步 NAS');
      } else {
        this.setToast(next ? '已本地收藏 · NAS 恢复后自动匹配同步' : '已本地取消 · NAS 恢复后自动同步');
      }
      return;
    }

    // NAS 曲目有稳定 source/id，在线时立即同步；失败则保留 pending，下次连接自动重试。
    try {
      if (!this.isRemoteSourceOnline(t.source)) throw new Error('source offline');
      await this.client.star(t, next);
      await this.removePendingFavoriteOp(t);
      this.liked = await this.client.liked();
      this.syncNasFavoriteCacheFromServer();
      await this.savePlaylistCache();
      this.applyPlaylistCacheState();
      this.setToast(next ? '已收藏' : '已取消收藏');
    } catch (_e) {
      this.setToast(next ? '已本地收藏 · 联网后自动同步' : '已本地取消 · 联网后自动同步');
    }
  }

  async like(): Promise<void> {
    const t = this.current();
    if (t === undefined) {
      return;
    }
    await this.likeTrack(t);
  }

  openDetailRoute(): void {
    this.page = 'main';
    this.detailNavStack.clear(false);
    const route: DetailRouteParam = { kind: this.detailKind, source: this.detailSource, id: this.detailId };
    this.detailNavStack.pushPath(new NavPathInfo('musicDetail', route), true);
  }

  closeDetailRoute(): void {
    if (this.detailNavStack.getAllPathName().length > 0) {
      this.detailNavStack.pop(true);
    }
  }

  sourceAllowed(s: SourceRow): boolean {
    return this.musicSourceMode === 2 ||
      (this.musicSourceMode === 0 && s.type === 'subsonic') ||
      (this.musicSourceMode === 1 && s.type === 'webdav');
  }

  hasOnlineMusicSource(): boolean {
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sourceAllowed(this.sources[i]) && this.sources[i].online) return true;
    }
    return false;
  }

  hasConfiguredMusicSource(): boolean {
    const cfgs = this.client.getSources();
    if (cfgs.length === 0) return false;
    for (let i = 0; i < cfgs.length; i++) {
      const type = cfgs[i].type === 'webdav' ? 'webdav' : 'subsonic';
      if (this.musicSourceMode === 2 || (this.musicSourceMode === 0 && type === 'subsonic') ||
        (this.musicSourceMode === 1 && type === 'webdav')) return true;
    }
    return false;
  }

  hasVisibleHomeMusic(): boolean {
    return this.newest.length > 0 || this.recent.length > 0 || this.songs.length > 0 ||
      this.albums.length > 0 || this.localSongs.length > 0 || this.liked.length > 0;
  }

  accountName(): string {
    for (let i = 0; i < this.sources.length; i++) {
      const s = this.sources[i];
      if (this.sourceAllowed(s) && s.online) return s.name;
    }
    if (this.hasConfiguredMusicSource()) return '无音乐来源';
    return '未添加音乐源';
  }

  sourceName(id: string): string {
    if (id === LOCAL_PLAYLIST_SOURCE) {
      return '本地歌单缓存';
    }
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sources[i].id === id) {
        return this.sources[i].name;
      }
    }
    return '音乐源';
  }

  sourceTypeLabel(type: string): string {
    return type === 'webdav' ? '网盘 · WebDAV' : 'NAS · Navidrome';
  }

  sourceModeLabel(): string {
    return this.musicSourceMode === 0 ? '仅 NAS' : (this.musicSourceMode === 1 ? '仅网盘' : '合并');
  }

  async setMusicSourceMode(mode: number): Promise<void> {
    if (mode === this.musicSourceMode) {
      return;
    }
    this.musicSourceMode = mode;
    this.client.setSourceMode(mode);
    await this.preferencesPut('musicSourceMode', '' + mode);
    this.client.invalidateCloud();
    try {
      await this.reloadServerSnapshot();
      this.setToast('音乐源：' + this.sourceModeLabel());
    } catch (e) {
      this.setToast('切换音乐源失败：' + errText(e as Object));
    }
  }

  preferredPlaylistSource(): string {
    if (this.plPickTrack !== undefined && this.client.sourceType(this.plPickTrack.source) === 'subsonic') {
      return this.plPickTrack.source;
    }
    const cur = this.current();
    if (cur !== undefined && this.client.sourceType(cur.source) === 'subsonic') {
      return cur.source;
    }
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sources[i].online && this.sources[i].type === 'subsonic') {
        return this.sources[i].id;
      }
    }
    return '';
  }

  pickPlaylists(): Playlist[] {
    const out: Playlist[] = [];
    const track = this.plPickTrack;
    const cloud = track !== undefined && this.client.sourceType(track.source) === 'webdav';
    for (let i = 0; i < this.playlists.length; i++) {
      if (cloud) {
        if (this.playlists[i].source === LOCAL_PLAYLIST_SOURCE) {
          out.push(this.playlists[i]);
        }
      } else if (track === undefined || this.playlists[i].source === track.source) {
        out.push(this.playlists[i]);
      }
    }
    return out;
  }

  async playPlaylistNow(p: Playlist): Promise<void> {
    if (p.available === false && p.source !== LOCAL_PLAYLIST_SOURCE) {
      const cached = this.remotePlaylistFallbackTracks(p);
      let first = -1;
      for (let i = 0; i < cached.length; i++) if (cached[i].available !== false) { first = i; break; }
      if (first >= 0) { await this.playList(cached, first); return; }
      this.setToast(CLOUD_OFFLINE_MESSAGE);
      return;
    }
    try {
      if (p.source === LOCAL_PLAYLIST_SOURCE) {
        const tracks = this.cachedPlaylistTracks(p.id);
        let first = -1;
        for (let i = 0; i < tracks.length; i++) {
          if (tracks[i].available !== false) {
            first = i;
            break;
          }
        }
        if (first < 0) {
          this.setToast(CLOUD_OFFLINE_MESSAGE);
          return;
        }
        await this.playList(tracks, first);
        return;
      }
      const full = await this.client.playlist(p.source, p.id);
      if (full.tracks.length > 0) {
        await this.playList(full.tracks, 0);
      }
    } catch (e) {
      this.err = errText(e as Object);
    }
  }

  setToast(msg: string, durationMs: number = 5000): void {
    this.toast = msg;
    this.toastAt = Date.now();
    this.toastDurationMs = Math.max(500, durationMs);
  }

  applyFx(): void {
    const p = this.av;
    if (p === undefined) {
      return;
    }
    try {
      p.audioEffectMode = this.audioFx
        ? audio.AudioEffectMode.EFFECT_DEFAULT
        : audio.AudioEffectMode.EFFECT_NONE;
    } catch (_e) {
    }
  }

  async preferencesPut(key: string, value: string): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, 'lumen');
      await p.put(key, value);
      await p.flush();
    } catch (_e) {
    }
  }

  cacheNorm(v: string): string {
    return v.trim().replace(/\s+/g, ' ').toLowerCase();
  }

  artistFollowKey(source: string, id: string, name: string): string {
    return source + '\u001F' + id + '\u001F' + this.cacheNorm(name);
  }

  isArtistFollowed(source: string, id: string, name: string): boolean {
    const norm = this.cacheNorm(name);
    for (let i = 0; i < this.followedArtistKeys.length; i++) {
      const parts = this.followedArtistKeys[i].split('\u001F');
      if (parts.length < 3 || parts[0] !== source) continue;
      const savedId = parts[1];
      const savedName = parts[2];
      if (id.length > 0 && savedId.length > 0 && id === savedId) return true;
      if (norm.length > 0 && savedName === norm) return true;
    }
    return false;
  }

  async loadFollowedArtists(): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.hostContext(), 'lumen');
      const raw = '' + await p.get('followedArtistsV1', '[]');
      const rows = JSON.parse(raw) as string[];
      this.followedArtistKeys = rows !== undefined ? rows : [];
    } catch (_e) {
      this.followedArtistKeys = [];
    }
  }

  async saveFollowedArtists(): Promise<void> {
    await this.preferencesPut('followedArtistsV1', JSON.stringify(this.followedArtistKeys));
  }

  async toggleDetailArtistFollow(): Promise<void> {
    if (this.detailKind !== 'artist') return;
    const followed = this.isArtistFollowed(this.detailSource, this.detailId, this.detailTitle);
    const next: string[] = [];
    for (let i = 0; i < this.followedArtistKeys.length; i++) {
      const parts = this.followedArtistKeys[i].split('\u001F');
      if (parts.length < 3) {
        next.push(this.followedArtistKeys[i]);
        continue;
      }
      const sameSource = parts[0] === this.detailSource;
      const sameId = this.detailId.length > 0 && parts[1].length > 0 && parts[1] === this.detailId;
      const sameName = parts[2] === this.cacheNorm(this.detailTitle);
      if (!(sameSource && (sameId || sameName))) next.push(this.followedArtistKeys[i]);
    }
    if (!followed) next.push(this.artistFollowKey(this.detailSource, this.detailId, this.detailTitle));
    this.followedArtistKeys = next;
    this.homeFeedSeed = Date.now();
    await this.saveFollowedArtists();
    this.setToast(followed ? '已取消关注' : '已关注 · 首页会提高相关歌曲的推荐概率', 2200);
  }

  homeFeedScore(t: Track): number {
    const seed = '' + Math.floor(this.homeFeedSeed / 60000);
    const text = seed + '|' + t.source + '|' + t.id + '|' + t.title;
    let hash = 17;
    for (let i = 0; i < text.length; i++) {
      hash = (hash * 131 + text.charCodeAt(i)) % 1000003;
    }
    let score = hash / 1000003;
    // 关注只提高首页靠前出现的概率，不等同于收藏，也不保证每首都排到最前。
    if (this.isArtistFollowed(t.source, t.artistId, t.artist)) score += 0.46;
    return score;
  }

  homeFeedSongs(): Track[] {
    const rows = this.mergedDiscoverableSongs();
    rows.sort((a: Track, b: Track) => this.homeFeedScore(b) - this.homeFeedScore(a));
    return rows;
  }

  cachedRefEqual(a: CachedSongRef, b: CachedSongRef): boolean {
    const as = a.source !== undefined ? a.source : '';
    const bs = b.source !== undefined ? b.source : '';
    const ai = a.id !== undefined ? a.id : '';
    const bi = b.id !== undefined ? b.id : '';
    if (as.length > 0 && bs.length > 0 && ai.length > 0 && bi.length > 0) return as === bs && ai === bi;
    return this.cacheNorm(a.title) === this.cacheNorm(b.title) && this.cacheNorm(a.artist) === this.cacheNorm(b.artist);
  }

  trackRef(t: Track): CachedSongRef {
    return { source: t.source, id: t.id, title: t.title.trim(), artist: t.artist.trim(), album: t.album,
      albumId: t.albumId, artistId: t.artistId, duration: t.duration, cover: t.cover,
      suffix: t.suffix !== undefined ? t.suffix : '' };
  }

  isRemoteSourceKnown(source: string): boolean {
    for (let i = 0; i < this.sources.length; i++) if (this.sources[i].id === source) return true;
    return false;
  }

  isRemoteSourceOnline(source: string): boolean {
    for (let i = 0; i < this.sources.length; i++) if (this.sources[i].id === source) return this.sources[i].online;
    return false;
  }

  isCloudSourceOnline(source: string): boolean { return this.isRemoteSourceOnline(source); }

  isCachedFavorite(ref: CachedSongRef): boolean {
    for (let i = 0; i < this.cloudFavoriteRefs.length; i++) if (this.cachedRefEqual(this.cloudFavoriteRefs[i], ref)) return true;
    return false;
  }

  cloneCloudTrack(t: Track, liked: boolean): Track {
    return { id: t.id, source: t.source, title: t.title, artist: t.artist, album: t.album, albumId: t.albumId,
      artistId: t.artistId, duration: t.duration, liked: liked, cover: t.cover, stream: t.stream,
      suffix: t.suffix, available: true, cached: true };
  }

  cachedPlaceholder(ref: CachedSongRef, liked: boolean): Track {
    const source = ref.source !== undefined && ref.source.length > 0 ? ref.source : LOCAL_PLAYLIST_SOURCE;
    const id = ref.id !== undefined && ref.id.length > 0 ? ref.id : 'cached-' + encodeURIComponent(ref.artist + '-' + ref.title);
    return { id: id, source: source, title: ref.title, artist: ref.artist,
      album: ref.album !== undefined ? ref.album : '', albumId: ref.albumId !== undefined ? ref.albumId : '',
      artistId: ref.artistId !== undefined ? ref.artistId : '', duration: ref.duration !== undefined ? ref.duration : 0,
      liked: liked, cover: ref.cover !== undefined ? ref.cover : '', stream: '',
      suffix: ref.suffix !== undefined ? ref.suffix : '', available: false, cached: true };
  }

  resolveCachedRef(ref: CachedSongRef): Track {
    const liked = this.isCachedFavorite(ref);
    const rs = ref.source !== undefined ? ref.source : '';
    const ri = ref.id !== undefined ? ref.id : '';
    if (rs.length > 0 && ri.length > 0 && this.isRemoteSourceOnline(rs)) {
      for (let i = 0; i < this.songs.length; i++) {
        const t = this.songs[i];
        if (t.source === rs && t.id === ri) return this.cloneCloudTrack(t, liked);
      }
    }
    for (let i = 0; i < this.songs.length; i++) {
      const t = this.songs[i];
      const type = this.client.sourceType(t.source);
      if (type === 'local' || t.source === LOCAL_PLAYLIST_SOURCE || !this.isRemoteSourceOnline(t.source)) continue;
      if (rs.length === 0 && type !== 'webdav') continue;
      if (rs.length > 0 && t.source !== rs) continue;
      if (this.cacheNorm(t.title) === this.cacheNorm(ref.title) && this.cacheNorm(t.artist) === this.cacheNorm(ref.artist)) {
        return this.cloneCloudTrack(t, liked);
      }
    }
    const placeholder = this.cachedPlaceholder(ref, liked);
    return this.preferLocalTrack(placeholder);
  }

  markCloudLikes(rows: Track[]): void {
    for (let i = 0; i < rows.length; i++) {
      const type = this.client.sourceType(rows[i].source);
      if ((type === 'webdav' || type === 'subsonic') && rows[i].source !== LOCAL_PLAYLIST_SOURCE) {
        const cachedLiked = this.isCachedFavorite(this.trackRef(rows[i]));
        if (type === 'webdav' || cachedLiked) rows[i].liked = cachedLiked;
        if (this.isRemoteSourceKnown(rows[i].source)) rows[i].available = this.isRemoteSourceOnline(rows[i].source);
      }
    }
  }

  upsertSongIndexFromTracks(rows: Track[]): void {
    for (let i = 0; i < rows.length; i++) {
      const t = rows[i];
      const type = this.client.sourceType(t.source);
      if (type === 'local' || t.source === LOCAL_PLAYLIST_SOURCE || t.suffix === 'radio') continue;
      const ref = this.trackRef(t);
      let found = -1;
      for (let j = 0; j < this.songIndexRefs.length; j++) {
        if (this.cachedRefEqual(this.songIndexRefs[j], ref)) { found = j; break; }
      }
      if (found >= 0) this.songIndexRefs[found] = ref; else this.songIndexRefs.push(ref);
    }
  }

  mergeOfflineSongIndex(): void {
    for (let i = 0; i < this.songIndexRefs.length; i++) {
      const ref = this.songIndexRefs[i];
      const source = ref.source !== undefined ? ref.source : '';
      if (source.length === 0 || !this.isRemoteSourceKnown(source) || this.isRemoteSourceOnline(source)) continue;
      let exists = false;
      for (let j = 0; j < this.songs.length; j++) {
        if (this.songs[j].source === source && ref.id !== undefined && this.songs[j].id === ref.id) { exists = true; break; }
      }
      if (!exists) this.songs.push(this.cachedPlaceholder(ref, this.isCachedFavorite(ref)));
    }
  }

  remotePlaylistCacheById(source: string, id: string): CachedRemotePlaylistRow | undefined {
    for (let i = 0; i < this.remotePlaylistCacheRows.length; i++) {
      const row = this.remotePlaylistCacheRows[i];
      if (row.source === source && row.id === id) return row;
    }
    return undefined;
  }

  playlistCoverCacheDir(): string {
    return this.localRootDir() + '/cover-cache';
  }

  ensurePlaylistCoverCacheDir(): void {
    try {
      this.ensureLocalFolders();
      const dir = this.playlistCoverCacheDir();
      if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir);
    } catch (_e) {
    }
  }

  playlistCoverCachePath(source: string, id: string): string {
    const key = source + '/' + id;
    let hash = 17;
    for (let i = 0; i < key.length; i++) hash = (hash * 131 + key.charCodeAt(i)) % 2147483647;
    return this.playlistCoverCacheDir() + '/playlist-' + hash + '.img';
  }

  async cachePlaylistCover(source: string, id: string, cover: string): Promise<string> {
    const url = this.client.abs(cover);
    if (url.length === 0 || url.startsWith('file://')) return url.startsWith('file://') ? url.substring(7) : '';
    this.ensurePlaylistCoverCacheDir();
    const path = this.playlistCoverCachePath(source, id);
    const h = http.createHttp();
    try {
      const r = await h.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 6000,
        readTimeout: 6000,
        usingCache: true
      });
      if (r.responseCode < 200 || r.responseCode >= 300) return '';
      try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_e) {}
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try { fileIo.writeSync(f.fd, r.result as ArrayBuffer); } finally { fileIo.closeSync(f); }
      return path;
    } catch (_e) {
      return '';
    } finally {
      h.destroy();
    }
  }

  playlistCoverFor(p: Playlist): string {
    if (p.source !== LOCAL_PLAYLIST_SOURCE) {
      const row = this.remotePlaylistCacheById(p.source, p.id);
      if (row !== undefined && row.localCover !== undefined && row.localCover.length > 0) {
        try { if (fileIo.accessSync(row.localCover)) return 'file://' + row.localCover; } catch (_e) {}
      }
    }
    return this.client.abs(p.cover);
  }

  remotePlaylistCachedSongCount(p: Playlist): number {
    const row = this.remotePlaylistCacheById(p.source, p.id);
    return row !== undefined ? row.songs.length : 0;
  }

  remotePlaylistFallbackTracks(p: Playlist): Track[] {
    const out: Track[] = [];
    const row = this.remotePlaylistCacheById(p.source, p.id);
    if (row !== undefined) {
      for (let i = 0; i < row.songs.length; i++) out.push(this.resolveCachedRef(row.songs[i]));
    }
    return out;
  }

  async mergeAndSaveRemotePlaylistSnapshot(p: Playlist, fresh: Track[], cover: string = ''): Promise<Track[]> {
    const refs: CachedSongRef[] = [];
    for (let i = 0; i < fresh.length; i++) refs.push(this.trackRef(fresh[i]));
    const coverValue = cover.length > 0 ? cover : p.cover;
    let localCover = '';
    const old = this.remotePlaylistCacheById(p.source, p.id);
    if (old !== undefined && old.localCover !== undefined) localCover = old.localCover;
    const downloadedCover = await this.cachePlaylistCover(p.source, p.id, coverValue);
    if (downloadedCover.length > 0) localCover = downloadedCover;

    const next: CachedRemotePlaylistRow[] = [];
    let replaced = false;
    for (let i = 0; i < this.remotePlaylistCacheRows.length; i++) {
      const row = this.remotePlaylistCacheRows[i];
      if (row.source === p.source && row.id === p.id) {
        next.push({ source: p.source, id: p.id, name: p.name, songs: refs, savedAt: Date.now(),
          songCount: p.songCount, cover: coverValue, localCover: localCover });
        replaced = true;
      } else next.push(row);
    }
    if (!replaced) next.push({ source: p.source, id: p.id, name: p.name, songs: refs, savedAt: Date.now(),
      songCount: p.songCount, cover: coverValue, localCover: localCover });
    this.remotePlaylistCacheRows = next;
    this.upsertSongIndexFromTracks(fresh);
    await this.savePlaylistCache();
    return fresh.slice();
  }

  async refreshRemotePlaylistCaches(): Promise<void> {
    const now = Date.now();
    for (let i = 0; i < this.playlists.length; i++) {
      const p = this.playlists[i];
      if (p.source === LOCAL_PLAYLIST_SOURCE || !this.isRemoteSourceOnline(p.source)) continue;
      const old = this.remotePlaylistCacheById(p.source, p.id);
      const stale = old === undefined || now - old.savedAt > 10 * 60 * 1000 ||
        (old.songCount !== undefined && old.songCount !== p.songCount);
      if (!stale) continue;
      try {
        const full = await this.client.playlist(p.source, p.id);
        const cover = full.cover.length > 0 ? full.cover : p.cover;
        await this.mergeAndSaveRemotePlaylistSnapshot(p, full.tracks !== undefined ? full.tracks : [], cover);
      } catch (_e) {
        // 保留上一次成功缓存；单个歌单失败不能清掉其它歌单。
      }
    }
  }

  cachedPlaylistById(id: string): CachedPlaylistRow | undefined {
    for (let i = 0; i < this.cloudPlaylistRows.length; i++) if (this.cloudPlaylistRows[i].id === id) return this.cloudPlaylistRows[i];
    return undefined;
  }

  cachedPlaylistTracks(id: string): Track[] {
    const p = this.cachedPlaylistById(id);
    const out: Track[] = [];
    if (p === undefined) return out;
    for (let i = 0; i < p.songs.length; i++) out.push(this.resolveCachedRef(p.songs[i]));
    return out;
  }

  syncNasFavoriteCacheFromServer(): void {
    const next: CachedSongRef[] = [];
    for (let i = 0; i < this.cloudFavoriteRefs.length; i++) {
      const ref = this.cloudFavoriteRefs[i];
      const source = ref.source !== undefined ? ref.source : '';
      if (source.length > 0 && this.client.sourceType(source) === 'subsonic' && this.isRemoteSourceOnline(source)) continue;
      next.push(ref);
    }
    for (let i = 0; i < this.liked.length; i++) {
      const t = this.liked[i];
      if (this.client.sourceType(t.source) !== 'subsonic' || t.available === false) continue;
      const ref = this.trackRef(t);
      let exists = false;
      for (let j = 0; j < next.length; j++) if (this.cachedRefEqual(next[j], ref)) { exists = true; break; }
      if (!exists) next.push(ref);
    }
    this.cloudFavoriteRefs = next;
  }

  mergeOfflineTrackRows(fresh: Track[], cached: Track[]): Track[] {
    const out: Track[] = fresh.slice();
    for (let i = 0; i < cached.length; i++) {
      const t = cached[i];
      if (!this.isRemoteSourceKnown(t.source) || this.isRemoteSourceOnline(t.source)) continue;
      if (this.client.sourceType(t.source) === 'local' || t.source === LOCAL_PLAYLIST_SOURCE) continue;
      let exists = false;
      for (let j = 0; j < out.length; j++) if (out[j].source === t.source && out[j].id === t.id) { exists = true; break; }
      if (!exists) {
        const copy = this.cloneCloudTrack(t, t.liked);
        copy.available = false;
        copy.cached = true;
        out.push(copy);
      }
    }
    return out;
  }

  mergeOfflinePlaylistRows(fresh: Playlist[], cached: Playlist[]): Playlist[] {
    const out: Playlist[] = fresh.slice();
    for (let i = 0; i < cached.length; i++) {
      const p = cached[i];
      if (p.source === LOCAL_PLAYLIST_SOURCE) continue;
      if (!this.isRemoteSourceKnown(p.source) || this.isRemoteSourceOnline(p.source)) continue;
      let exists = false;
      for (let j = 0; j < out.length; j++) if (out[j].source === p.source && out[j].id === p.id) { exists = true; break; }
      if (!exists) {
        const row = this.remotePlaylistCacheById(p.source, p.id);
        let cover = p.cover;
        if (row !== undefined) {
          if (row.cover !== undefined && row.cover.length > 0) cover = row.cover;
          if (row.localCover !== undefined && row.localCover.length > 0) {
            try { if (fileIo.accessSync(row.localCover)) cover = 'file://' + row.localCover; } catch (_e) {}
          }
        }
        out.push({ id: p.id, source: p.source, name: p.name, songCount: p.songCount,
          cover: cover, local: p.local, available: false, cached: true });
      }
    }
    return out;
  }

  async mergeOfflineMetadataSnapshot(): Promise<void> {
    const cached = await this.readMetadataSnapshotData();
    if (cached === undefined) return;
    // 离线只保留用户明确关心的“收藏”和“歌单”记忆。
    // 整个 NAS 曲库不能伪装成仍在线，否则首页会随机出现一批实际不可播放的旧歌曲。
    this.liked = this.mergeOfflineTrackRows(this.liked, cached.liked !== undefined ? cached.liked : []);
    this.playlists = this.mergeOfflinePlaylistRows(this.playlists, cached.playlists !== undefined ? cached.playlists : []);
  }

  applyPlaylistCacheState(): void {
    this.markCloudLikes(this.songs);
    this.markCloudLikes(this.hitSongs);
    this.markCloudLikes(this.detailTracks);
    this.markCloudLikes(this.queue);
    for (let i = 0; i < this.localSongs.length; i++) {
      this.localSongs[i].liked = this.isCachedFavorite(this.trackRef(this.localSongs[i]));
    }
    this.localSongs = this.localSongs.slice();
    const serverPlaylists: Playlist[] = [];
    for (let i = 0; i < this.playlists.length; i++) if (this.playlists[i].source !== LOCAL_PLAYLIST_SOURCE) serverPlaylists.push(this.playlists[i]);
    for (let i = 0; i < this.remotePlaylistCacheRows.length; i++) {
      const row = this.remotePlaylistCacheRows[i];
      if (!this.isRemoteSourceKnown(row.source) || this.isRemoteSourceOnline(row.source)) continue;
      let exists = false;
      for (let j = 0; j < serverPlaylists.length; j++) {
        if (serverPlaylists[j].source === row.source && serverPlaylists[j].id === row.id) { exists = true; break; }
      }
      if (!exists) {
        let cover = row.cover !== undefined ? row.cover : '';
        if (row.localCover !== undefined && row.localCover.length > 0) {
          try { if (fileIo.accessSync(row.localCover)) cover = 'file://' + row.localCover; } catch (_e) {}
        }
        serverPlaylists.push({ id: row.id, source: row.source, name: row.name,
          songCount: row.songCount !== undefined && row.songCount > 0 ? row.songCount : row.songs.length,
          cover: cover, available: false, cached: true });
      }
    }
    for (let i = 0; i < this.cloudPlaylistRows.length; i++) {
      const row = this.cloudPlaylistRows[i];
      const tracks = this.cachedPlaylistTracks(row.id);
      let cover = '';
      for (let j = 0; j < tracks.length; j++) if (tracks[j].cover.length > 0) { cover = tracks[j].cover; break; }
      serverPlaylists.push({ id: row.id, source: LOCAL_PLAYLIST_SOURCE, name: row.name, songCount: row.songs.length,
        cover: cover, local: true, available: true, cached: true });
    }
    this.playlists = serverPlaylists;
    const serverLiked: Track[] = [];
    for (let i = 0; i < this.liked.length; i++) serverLiked.push(this.liked[i]);
    for (let i = 0; i < this.cloudFavoriteRefs.length; i++) {
      const ref = this.cloudFavoriteRefs[i];
      let exists = false;
      for (let j = 0; j < serverLiked.length; j++) {
        if (this.cachedRefEqual(this.trackRef(serverLiked[j]), ref) ||
          (this.cacheNorm(serverLiked[j].title) === this.cacheNorm(ref.title) &&
            this.cacheNorm(serverLiked[j].artist) === this.cacheNorm(ref.artist))) { exists = true; break; }
      }
      if (!exists) serverLiked.push(this.resolveCachedRef(ref));
    }
    this.liked = serverLiked;
    const cur = this.current();
    if (cur !== undefined) {
      const type = this.client.sourceType(cur.source);
      if ((type === 'webdav' || type === 'subsonic') && this.isCachedFavorite(this.trackRef(cur))) {
        this.nowLiked = true;
        cur.liked = true;
      }
    }
    let cachedSongs = this.cloudFavoriteRefs.length;
    for (let i = 0; i < this.cloudPlaylistRows.length; i++) cachedSongs += this.cloudPlaylistRows[i].songs.length;
    this.playlistCacheSongCount = cachedSongs;
    this.playlistCachePlaylistCount = this.cloudPlaylistRows.length;
    this.songs = this.songs.slice(); this.hitSongs = this.hitSongs.slice(); this.detailTracks = this.detailTracks.slice(); this.queue = this.queue.slice();
  }

  cachedRefFromObject(row: Record<string, Object>): CachedSongRef | undefined {
    const title = '' + (row['title'] !== undefined ? row['title'] : '');
    const artist = '' + (row['artist'] !== undefined ? row['artist'] : '');
    if (title.trim().length === 0) return undefined;
    return { source: '' + (row['source'] !== undefined ? row['source'] : ''), id: '' + (row['id'] !== undefined ? row['id'] : ''),
      title: title, artist: artist, album: '' + (row['album'] !== undefined ? row['album'] : ''),
      albumId: '' + (row['albumId'] !== undefined ? row['albumId'] : ''), artistId: '' + (row['artistId'] !== undefined ? row['artistId'] : ''),
      duration: Number(row['duration'] !== undefined ? row['duration'] : 0), cover: '' + (row['cover'] !== undefined ? row['cover'] : ''),
      suffix: '' + (row['suffix'] !== undefined ? row['suffix'] : '') };
  }

  async loadPlaylistCache(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, PLAYLIST_CACHE_PREF);
      const raw = '' + (await p.get(PLAYLIST_CACHE_KEY, '{"favorites":[],"playlists":[]}'));
      const obj = JSON.parse(raw) as Record<string, Object>;
      const fav = obj['favorites'] as Array<Record<string, Object>>;
      const pls = obj['playlists'] as Array<Record<string, Object>>;
      const favOut: CachedSongRef[] = [];
      const plOut: CachedPlaylistRow[] = [];
      const remoteOut: CachedRemotePlaylistRow[] = [];
      const indexOut: CachedSongRef[] = [];
      const pendingOut: PendingFavoriteOp[] = [];
      if (fav !== undefined) {
        for (let i = 0; i < fav.length; i++) {
          const ref = this.cachedRefFromObject(fav[i]);
          if (ref !== undefined) favOut.push(ref);
        }
      }
      if (pls !== undefined) {
        for (let i = 0; i < pls.length; i++) {
          const id = '' + (pls[i]['id'] !== undefined ? pls[i]['id'] : '');
          const name = '' + (pls[i]['name'] !== undefined ? pls[i]['name'] : '');
          const songs0 = pls[i]['songs'] as Array<Record<string, Object>>;
          const songs: CachedSongRef[] = [];
          if (songs0 !== undefined) {
            for (let j = 0; j < songs0.length; j++) {
              const ref = this.cachedRefFromObject(songs0[j]);
              if (ref !== undefined) songs.push(ref);
            }
          }
          if (id.length > 0 && name.trim().length > 0) plOut.push({ id: id, name: name, songs: songs });
        }
      }
      const remote = obj['remotePlaylists'] as Array<Record<string, Object>>;
      if (remote !== undefined) {
        for (let i = 0; i < remote.length; i++) {
          const source = '' + (remote[i]['source'] !== undefined ? remote[i]['source'] : '');
          const id = '' + (remote[i]['id'] !== undefined ? remote[i]['id'] : '');
          const name = '' + (remote[i]['name'] !== undefined ? remote[i]['name'] : '');
          const savedAt = Number(remote[i]['savedAt'] !== undefined ? remote[i]['savedAt'] : 0);
          const songCount = Number(remote[i]['songCount'] !== undefined ? remote[i]['songCount'] : 0);
          const cover = '' + (remote[i]['cover'] !== undefined ? remote[i]['cover'] : '');
          const localCover = '' + (remote[i]['localCover'] !== undefined ? remote[i]['localCover'] : '');
          const songs0 = remote[i]['songs'] as Array<Record<string, Object>>;
          const songs: CachedSongRef[] = [];
          if (songs0 !== undefined) for (let j = 0; j < songs0.length; j++) {
            const ref = this.cachedRefFromObject(songs0[j]); if (ref !== undefined) songs.push(ref);
          }
          if (source.length > 0 && id.length > 0) remoteOut.push({ source: source, id: id, name: name, songs: songs, savedAt: savedAt,
            songCount: songCount, cover: cover, localCover: localCover });
        }
      }
      const songIndex = obj['songIndex'] as Array<Record<string, Object>>;
      if (songIndex !== undefined) for (let i = 0; i < songIndex.length; i++) {
        const ref = this.cachedRefFromObject(songIndex[i]); if (ref !== undefined) indexOut.push(ref);
      }
      const pending = obj['pendingFavorites'] as Array<Record<string, Object>>;
      if (pending !== undefined) for (let i = 0; i < pending.length; i++) {
        const title = '' + (pending[i]['title'] !== undefined ? pending[i]['title'] : '');
        if (title.trim().length === 0) continue;
        pendingOut.push({
          source: '' + (pending[i]['source'] !== undefined ? pending[i]['source'] : ''),
          id: '' + (pending[i]['id'] !== undefined ? pending[i]['id'] : ''),
          title: title,
          artist: '' + (pending[i]['artist'] !== undefined ? pending[i]['artist'] : ''),
          album: '' + (pending[i]['album'] !== undefined ? pending[i]['album'] : ''),
          liked: ('' + (pending[i]['liked'] !== undefined ? pending[i]['liked'] : 'false')) === 'true',
          createdAt: Number(pending[i]['createdAt'] !== undefined ? pending[i]['createdAt'] : 0)
        });
      }
      this.cloudFavoriteRefs = favOut;
      this.cloudPlaylistRows = plOut;
      this.remotePlaylistCacheRows = remoteOut;
      this.songIndexRefs = indexOut;
      this.pendingFavoriteOps = pendingOut;
    } catch (_e) {
      this.cloudFavoriteRefs = [];
      this.cloudPlaylistRows = [];
      this.remotePlaylistCacheRows = [];
      this.songIndexRefs = [];
      this.pendingFavoriteOps = [];
    }
  }

  async savePlaylistCache(): Promise<void> {
    try {
      const ctx = this.hostContext();
      const p = await preferences.getPreferences(ctx, PLAYLIST_CACHE_PREF);
      const data: PlaylistCacheData = { favorites: this.cloudFavoriteRefs, playlists: this.cloudPlaylistRows,
        remotePlaylists: this.remotePlaylistCacheRows, songIndex: this.songIndexRefs,
        pendingFavorites: this.pendingFavoriteOps };
      await p.put(PLAYLIST_CACHE_KEY, JSON.stringify(data));
      await p.flush();
    } catch (_e) {
    }
  }

  playlistCacheSummary(): string {
    return this.cloudFavoriteRefs.length + ' 首收藏缓存 · ' +
      this.playlistCachePlaylistCount + ' 个本地歌单 · ' + this.playlistCacheSongCount + ' 条缓存记录' +
      (this.pendingFavoriteOps.length > 0 ? (' · ' + this.pendingFavoriteOps.length + ' 条待同步') : '');
  }

  async clearPlaylistCache(): Promise<void> {
    this.cloudFavoriteRefs = [];
    this.cloudPlaylistRows = [];
    this.remotePlaylistCacheRows = [];
    this.songIndexRefs = [];
    this.pendingFavoriteOps = [];
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
    this.setToast('歌单缓存已清理');
  }

  pendingFavoriteSame(op: PendingFavoriteOp, t: Track): boolean {
    if (op.source === t.source && op.id.length > 0 && t.id.length > 0) return op.id === t.id;
    return this.cacheNorm(op.title) === this.cacheNorm(t.title) && this.cacheNorm(op.artist) === this.cacheNorm(t.artist);
  }

  async enqueuePendingFavoriteOp(t: Track, liked: boolean): Promise<void> {
    const next: PendingFavoriteOp[] = [];
    for (let i = 0; i < this.pendingFavoriteOps.length; i++) {
      if (!this.pendingFavoriteSame(this.pendingFavoriteOps[i], t)) next.push(this.pendingFavoriteOps[i]);
    }
    next.push({ source: t.source, id: t.id, title: t.title, artist: t.artist, album: t.album,
      liked: liked, createdAt: Date.now() });
    this.pendingFavoriteOps = next;
    await this.savePlaylistCache();
  }

  async removePendingFavoriteOp(t: Track): Promise<void> {
    const next: PendingFavoriteOp[] = [];
    for (let i = 0; i < this.pendingFavoriteOps.length; i++) {
      if (!this.pendingFavoriteSame(this.pendingFavoriteOps[i], t)) next.push(this.pendingFavoriteOps[i]);
    }
    this.pendingFavoriteOps = next;
    await this.savePlaylistCache();
  }

  favoriteLooseNorm(v: string): string {
    return this.cacheNorm(v)
      .replace(/[\s_\-.,'"(){}\[\]\/\\&+|]/g, '')
      .replace(/[\u00B7\u3001\u3002\uFF0C\uFF08\uFF09\u3010\u3011]/g, '');
  }

  findNasMatchForPending(op: PendingFavoriteOp): Track | undefined {
    // NAS 原始曲目优先按稳定 source/id 恢复，不需要模糊匹配。
    if (op.source !== LOCAL_SOURCE && op.id.length > 0 && this.client.sourceType(op.source) === 'subsonic' &&
      this.isRemoteSourceOnline(op.source)) {
      for (let i = 0; i < this.songs.length; i++) {
        if (this.songs[i].source === op.source && this.songs[i].id === op.id) return this.songs[i];
      }
    }

    // 纯本地歌曲先做保守匹配：歌名规范化一致，作者完全一致或一方包含另一方。
    // 多个候选时宁可不自动同步，避免收藏错歌；以后可在这里接 MusicBrainz/刮削源等二次匹配。
    const title = this.favoriteLooseNorm(op.title);
    const artist = this.favoriteLooseNorm(op.artist);
    let hit: Track | undefined = undefined;
    for (let i = 0; i < this.songs.length; i++) {
      const t = this.songs[i];
      if (this.client.sourceType(t.source) !== 'subsonic' || !this.isRemoteSourceOnline(t.source)) continue;
      if (this.favoriteLooseNorm(t.title) !== title) continue;
      const ta = this.favoriteLooseNorm(t.artist);
      const artistOk = artist.length === 0 || artist === '本地音乐' || ta === artist ||
        (artist.length >= 4 && ta.indexOf(artist) >= 0) || (ta.length >= 4 && artist.indexOf(ta) >= 0);
      if (!artistOk) continue;
      if (hit !== undefined && (hit.source !== t.source || hit.id !== t.id)) return undefined;
      hit = t;
    }
    return hit;
  }

  async syncPendingFavoriteOps(): Promise<void> {
    if (this.favoriteSyncRunning || this.pendingFavoriteOps.length === 0 || !this.hasOnlineMusicSource()) return;
    this.favoriteSyncRunning = true;
    try {
      const pending = this.pendingFavoriteOps.slice();
      const remain: PendingFavoriteOp[] = [];
      let synced = 0;
      for (let i = 0; i < pending.length; i++) {
        const op = pending[i];
        const target = this.findNasMatchForPending(op);
        if (target === undefined) {
          remain.push(op);
          continue;
        }
        try {
          await this.client.star(target, op.liked);
          synced++;
        } catch (_e) {
          remain.push(op);
        }
      }
      this.pendingFavoriteOps = remain;
      if (synced > 0) {
        try { this.liked = await this.client.liked(); } catch (_e) {}
        this.syncNasFavoriteCacheFromServer();
        this.applyPlaylistCacheState();
        this.enrichLocalSongsFromNas();
      }
      await this.savePlaylistCache();
    } finally {
      this.favoriteSyncRunning = false;
    }
  }

  async setCloudFavorite(t: Track, liked: boolean): Promise<void> {
    const ref = this.trackRef(t);
    const next: CachedSongRef[] = [];
    let existed = false;
    for (let i = 0; i < this.cloudFavoriteRefs.length; i++) {
      if (this.cachedRefEqual(this.cloudFavoriteRefs[i], ref)) {
        existed = true;
      } else {
        next.push(this.cloudFavoriteRefs[i]);
      }
    }
    if (liked && !existed) {
      next.push(ref);
    }
    this.cloudFavoriteRefs = next;
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
  }

  async createCachedPlaylist(name: string, t: Track | undefined): Promise<void> {
    const songs: CachedSongRef[] = [];
    if (t !== undefined) {
      songs.push(this.trackRef(t));
    }
    this.cloudPlaylistRows.push({ id: 'lp-' + Date.now(), name: name, songs: songs });
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
  }

  async addTrackToCachedPlaylist(id: string, t: Track): Promise<void> {
    const p = this.cachedPlaylistById(id);
    if (p === undefined) {
      throw new Error('本地歌单不存在');
    }
    const ref = this.trackRef(t);
    for (let i = 0; i < p.songs.length; i++) {
      if (this.cachedRefEqual(p.songs[i], ref)) {
        return;
      }
    }
    p.songs.push(ref);
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
  }

  async renameCachedPlaylist(id: string, name: string): Promise<void> {
    const p = this.cachedPlaylistById(id);
    if (p === undefined) {
      throw new Error('本地歌单不存在');
    }
    p.name = name;
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
  }

  async deleteCachedPlaylist(id: string): Promise<void> {
    const out: CachedPlaylistRow[] = [];
    for (let i = 0; i < this.cloudPlaylistRows.length; i++) {
      if (this.cloudPlaylistRows[i].id !== id) {
        out.push(this.cloudPlaylistRows[i]);
      }
    }
    this.cloudPlaylistRows = out;
    await this.savePlaylistCache();
    this.applyPlaylistCacheState();
  }

  async loadSources(): Promise<void> {
    const ctx = this.hostContext();
    const cfgs = await MusicSourceManager.loadSourceCfgs(ctx);
    this.client.setSourceMode(this.musicSourceMode);
    this.client.setSources(cfgs);
    this.sources = await this.client.sources();
  }

  editSource(id: string): void {
    const cfgs = this.client.getSources();
    for (let i = 0; i < cfgs.length; i++) {
      if (cfgs[i].id === id) {
        this.srcEditId = id;
        this.srcName = cfgs[i].name;
        this.srcUrl = cfgs[i].url;
        this.srcUser = cfgs[i].user;
        this.srcPass = cfgs[i].pass;
        this.srcKind = cfgs[i].type === 'webdav' ? 'webdav' : 'subsonic';
        this.srcMsg = '正在编辑「' + cfgs[i].name + '」，改完点保存';
        this.srcOk = false;
        return;
      }
    }
  }

  async probeSource(): Promise<void> {
    if (this.srcBusy || this.srcUrl.trim().length === 0) {
      return;
    }
    this.srcBusy = true;
    this.srcMsg = '';
    try {
      const cfg: SourceCfg = {
        id: 'probe', name: '', url: this.srcUrl.trim(),
        user: this.srcUser.trim(), pass: this.srcPass, type: this.srcKind
      };
      const ver = this.srcKind === 'webdav' ? await new WebDavApi(cfg).ping() : await new SubApi(cfg).ping();
      this.srcOk = true;
      this.srcMsg = '连接成功' + (ver.length > 0 ? '（' + ver + '）' : '');
    } catch (e) {
      this.srcOk = false;
      this.srcMsg = '连不上：' + errText(e as Object);
    }
    this.srcBusy = false;
  }

  async addSource(): Promise<void> {
    if (this.srcBusy || this.srcUrl.trim().length === 0) {
      return;
    }
    this.srcBusy = true;
    this.srcMsg = '';
    const editing = this.srcEditId.length > 0;
    try {
      const ctx = this.hostContext();
      const cfgs = await MusicSourceManager.loadSourceCfgs(ctx);
      const cfg: SourceCfg = {
        id: editing ? this.srcEditId : Date.now().toString(16),
        name: this.srcName.trim().length > 0 ? this.srcName.trim() : (this.srcKind === 'webdav' ? '网盘' : 'Navidrome'),
        url: this.srcUrl.trim(),
        user: this.srcUser.trim(),
        pass: this.srcPass,
        type: this.srcKind
      };
      if (this.srcKind === 'webdav') {
        await new WebDavApi(cfg).ping();
      } else {
        await new SubApi(cfg).ping();
      }
      if (editing) {
        for (let i = 0; i < cfgs.length; i++) {
          if (cfgs[i].id === cfg.id) {
            cfgs[i] = cfg;
          }
        }
      } else {
        cfgs.push(cfg);
      }
      await MusicSourceManager.saveSourceCfgs(ctx, cfgs);
      this.client.setSourceMode(this.musicSourceMode);
      this.client.setSources(cfgs);
      this.sources = await this.client.sources();
      this.srcName = '';
      this.srcUrl = '';
      this.srcUser = '';
      this.srcPass = '';
      this.srcEditId = '';
      this.srcOk = true;
      this.srcMsg = editing ? '已保存修改' : (this.srcKind === 'webdav' ? '已添加网盘音乐源' : '已添加 NAS 音乐源');
      this.err = '';
      await this.reloadServerSnapshot();
    } catch (e) {
      this.srcOk = false;
      this.srcMsg = (editing ? '保存失败：' : '添加失败：') + errText(e as Object);
    }
    this.srcBusy = false;
  }

  async removeSource(id: string): Promise<void> {
    const ctx = this.hostContext();
    const cfgs = await MusicSourceManager.loadSourceCfgs(ctx);
    const out: SourceCfg[] = [];
    for (let i = 0; i < cfgs.length; i++) {
      if (cfgs[i].id !== id) {
        out.push(cfgs[i]);
      }
    }
    await MusicSourceManager.saveSourceCfgs(ctx, out);
    this.client.setSources(out);
    this.sources = await this.client.sources();
    this.setToast('已删除音乐源');
    this.err = '';
    await this.reloadServerSnapshot();
  }

  openManage(p: Playlist): void {
    this.manageSrc = p.source;
    this.manageId = p.id;
    this.manageName = p.name;
    this.plDlgName = p.name;
    this.manageOpen = true;
  }

  async confirmPlDlg(): Promise<void> {
    const name = this.plDlgName.trim();
    if (name.length === 0 || this.srcBusy) {
      return;
    }
    this.srcBusy = true;
    try {
      if (this.plDlgMode === 1) {
        const track = this.plPickOn ? this.plPickTrack : undefined;
        const cloudCreate = (track !== undefined && this.client.sourceType(track.source) === 'webdav') ||
          (track === undefined && this.musicSourceMode === 1);
        if (cloudCreate) {
          await this.createCachedPlaylist(name, track);
          this.setToast('已创建本地歌单「' + name + '」');
        } else {
          const ids: string[] = [];
          const source = this.preferredPlaylistSource();
          if (source.length === 0) {
            // 没有 Navidrome 时仍允许创建空的本地网盘歌单。
            await this.createCachedPlaylist(name, track);
            this.setToast('已创建本地歌单「' + name + '」');
          } else {
            if (track !== undefined) {
              ids.push(track.id);
            }
            await this.client.createPlaylist(source, name, ids);
            this.setToast('已创建「' + name + '」 · ' + this.sourceName(source));
          }
        }
      } else if (this.plDlgMode === 2) {
        if (this.manageSrc === LOCAL_PLAYLIST_SOURCE) {
          await this.renameCachedPlaylist(this.manageId, name);
        } else {
          await this.client.renamePlaylist(this.manageSrc, this.manageId, name);
        }
        this.setToast('已重命名');
      }
      this.plDlgMode = 0;
      this.manageOpen = false;
      this.plPickOn = false;
      await this.loadMe();
      this.plDlgName = '';
    } catch (e) {
      this.err = '' + e;
    }
    this.srcBusy = false;
  }

  async deleteManage(): Promise<void> {
    this.srcBusy = true;
    try {
      if (this.manageSrc === LOCAL_PLAYLIST_SOURCE) {
        await this.deleteCachedPlaylist(this.manageId);
      } else {
        await this.client.deletePlaylist(this.manageSrc, this.manageId);
      }
      this.manageOpen = false;
      this.setToast('已删除歌单');
      await this.loadMe();
    } catch (e) {
      this.err = '' + e;
    }
    this.srcBusy = false;
  }

  async shareManage(): Promise<void> {
    try {
      if (this.manageSrc === LOCAL_PLAYLIST_SOURCE) {
        this.manageOpen = false;
        this.setToast('本地网盘歌单不生成服务器分享码');
        return;
      }
      const full = await this.client.playlist(this.manageSrc, this.manageId);
      const ids: string[] = [];
      const tracks = full.tracks !== undefined ? full.tracks : [];
      for (let i = 0; i < tracks.length; i++) {
        ids.push(tracks[i].id);
      }
      const payload = JSON.stringify({ n: this.manageName, s: this.manageSrc, sn: this.sourceName(this.manageSrc), i: ids });
      const b64 = new util.Base64Helper().encodeToStringSync(
        new Uint8Array(buffer.from(payload, 'utf-8').buffer));
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, 'LM2.' + b64);
      pasteboard.getSystemPasteboard().setData(data);
      this.manageOpen = false;
      this.setToast('分享码已复制（' + ids.length + ' 首）');
    } catch (e) {
      this.err = '' + e;
    }
  }

  async importShare(): Promise<void> {
    const code = this.importCode.trim();
    if (code.length === 0 || this.srcBusy) {
      return;
    }
    this.srcBusy = true;
    try {
      const b64 = code.startsWith('LM2.') || code.startsWith('LM1.') ? code.substring(4) : code;
      const u8 = new util.Base64Helper().decodeSync(b64);
      const payload = JSON.parse(buffer.from(u8.buffer).toString()) as Record<string, Object>;
      const name = '' + (payload['n'] !== undefined ? payload['n'] : '导入的歌单');
      const ids = payload['i'] as Array<string>;
      const list: string[] = [];
      if (ids !== undefined) {
        for (let i = 0; i < ids.length; i++) {
          list.push('' + ids[i]);
        }
      }
      let source = payload['s'] !== undefined ? '' + payload['s'] : '';
      let sourceExists = false;
      for (let i = 0; i < this.sources.length; i++) {
        if (this.sources[i].id === source) {
          sourceExists = true;
          break;
        }
      }
      if (!sourceExists && payload['sn'] !== undefined) {
        const sourceName = '' + payload['sn'];
        for (let i = 0; i < this.sources.length; i++) {
          if (this.sources[i].name === sourceName) {
            source = this.sources[i].id;
            sourceExists = true;
            break;
          }
        }
      }
      if (!sourceExists && list.length > 0) {
        source = await this.client.detectSongSource(list[0]);
        sourceExists = true;
      }
      if (!sourceExists) {
        source = this.preferredPlaylistSource();
      }
      if (source.length === 0) {
        throw new Error('无法确定歌单要导入到哪个音乐源');
      }
      for (let i = 0; i < this.playlists.length; i++) {
        if (this.playlists[i].source === source && this.playlists[i].name === name) {
          throw new Error('「' + this.sourceName(source) + '」已存在同名歌单「' + name + '」');
        }
      }
      await this.client.createPlaylist(source, name, list);
      this.importOpen = false;
      this.importCode = '';
      this.setToast('已导入「' + name + '」（' + list.length + ' 首）· ' + this.sourceName(source));
      await this.loadMe();
    } catch (e) {
      this.err = '导入失败：' + errText(e as Object);
    }
    this.srcBusy = false;
  }

  async addPick(pl: Playlist): Promise<void> {
    if (this.plPickTrack === undefined) {
      return;
    }
    this.srcBusy = true;
    try {
      if (pl.source === LOCAL_PLAYLIST_SOURCE) {
        await this.addTrackToCachedPlaylist(pl.id, this.plPickTrack);
      } else {
        await this.client.addToPlaylist(pl.source, pl.id, this.plPickTrack);
      }
      this.plPickOn = false;
      this.setToast('已加入「' + pl.name + '」');
    } catch (e) {
      this.err = '加入失败：' + errText(e as Object);
    }
    this.srcBusy = false;
  }

  async loadMe(): Promise<void> {
    await this.reloadServerSnapshot();
    await this.syncPendingFavoriteOps();
  }

  async retrySources(): Promise<void> {
    this.err = '';
    AppStorage.setOrCreate('lumenOfflineHint', '');
    try {
      await this.reloadServerSnapshot();
      await this.syncPendingFavoriteOps();
      if (this.hasOnlineMusicSource()) this.setToast('音乐源已恢复');
    } catch (e) {
      this.setToast('仍无法连接：' + errText(e as Object));
    }
  }

  async openAlbum(a: Album, x: number = 0, y: number = 0, w: number = 168, h: number = 168, lx: number = -1, ly: number = -1): Promise<void> {
    const loadToken = ++this.detailLoadToken;
    this.detailKind = 'album';
    this.detailSource = a.source;
    this.detailId = a.id;
    this.detailTitle = a.title;
    this.detailSub = a.artist;
    this.detailCover = this.client.abs(a.cover);
    this.pullMood(this.detailCover, true);
    this.detailTracks = [];
    this.openDetailRoute();
    try {
      const full = await this.client.album(a.source, a.id);
      if (loadToken !== this.detailLoadToken || this.detailSource !== a.source || this.detailId !== a.id) {
        return;
      }
      this.detailTitle = full.title;
      this.detailSub = full.artist;
      this.detailCover = this.client.abs(full.cover);
      this.detailTracks = full.tracks !== undefined ? full.tracks : [];
      this.markCloudLikes(this.detailTracks);
      this.detailTracks = this.detailTracks.slice();
    } catch (e) {
      this.err = '' + e;
    }
  }

  async openArtist(a: Artist, x: number = 0, y: number = 0, w: number = 88, h: number = 88, lx: number = -1, ly: number = -1): Promise<void> {
    const loadToken = ++this.detailLoadToken;
    this.detailKind = 'artist';
    this.detailSource = a.source;
    this.detailId = a.id;
    this.detailTitle = a.name;
    this.detailSub = '';
    this.detailCover = this.client.abs(a.cover);
    this.pullMood(this.detailCover, true);
    this.detailTracks = [];
    this.artistAlbums = [];
    this.openDetailRoute();
    try {
      const full = await this.client.artist(a.source, a.id);
      if (loadToken !== this.detailLoadToken || this.detailSource !== a.source || this.detailId !== a.id) {
        return;
      }
      this.detailTitle = full.name;
      this.detailCover = this.client.abs(full.cover);
      this.artistAlbums = full.albums !== undefined ? full.albums : [];
      try {
        const top = await this.client.artistTopSongs(a.source, full.name, 100);
        if (loadToken === this.detailLoadToken && this.detailSource === a.source && this.detailId === a.id) {
          this.detailTracks = top;
          this.markCloudLikes(this.detailTracks);
          this.detailTracks = this.detailTracks.slice();
        }
      } catch (_top) {
        if (loadToken === this.detailLoadToken && this.detailSource === a.source && this.detailId === a.id) {
          this.detailTracks = [];
        }
      }
    } catch (e) {
      this.err = '' + e;
    }
  }

  async openPlaylist(p: Playlist, x: number = 0, y: number = 0, w: number = 56, h: number = 56, lx: number = -1, ly: number = -1): Promise<void> {
    const loadToken = ++this.detailLoadToken;
    this.detailKind = 'playlist';
    this.detailSource = p.source;
    this.detailId = p.id;
    this.detailTitle = p.name;
    this.detailSub = p.available === false ? ('离线缓存 · ' + this.remotePlaylistCachedSongCount(p) + '/' + p.songCount + ' 首') : '';
    this.detailCover = this.playlistCoverFor(p);
    this.pullMood(this.detailCover, true);
    this.detailTracks = [];
    this.openDetailRoute();
    try {
      if (p.source === LOCAL_PLAYLIST_SOURCE) {
        const row = this.cachedPlaylistById(p.id);
        if (row === undefined) throw new Error('本地歌单缓存不存在');
        if (loadToken !== this.detailLoadToken || this.detailSource !== p.source || this.detailId !== p.id) return;
        this.detailTitle = row.name;
        this.detailTracks = this.cachedPlaylistTracks(p.id);
        this.detailCover = '';
        for (let i = 0; i < this.detailTracks.length; i++) {
          if (this.detailTracks[i].cover.length > 0) { this.detailCover = this.client.abs(this.detailTracks[i].cover); break; }
        }
        return;
      }

      // 远端歌单离线时只展示真实缓存过的歌曲，不伪造占位条目。
      this.detailTracks = this.remotePlaylistFallbackTracks(p);
      if (p.available === false) {
        this.detailSub = '离线缓存 · ' + this.detailTracks.length + '/' + p.songCount + ' 首';
        if (this.detailTracks.length === 0) this.setToast('这个歌单还没有离线缓存内容');
        return;
      }
      const full = await this.client.playlist(p.source, p.id);
      if (loadToken !== this.detailLoadToken || this.detailSource !== p.source || this.detailId !== p.id) return;
      this.detailTitle = full.name;
      const fresh = full.tracks !== undefined ? full.tracks : [];
      this.detailTracks = await this.mergeAndSaveRemotePlaylistSnapshot(p, fresh, full.cover);
      this.detailCover = this.playlistCoverFor(p);
      this.detailSub = '';
      this.markCloudLikes(this.detailTracks);
      this.detailTracks = this.detailTracks.slice();
      if (this.detailCover.length === 0) {
        for (let i = 0; i < this.detailTracks.length; i++) if (this.detailTracks[i].cover.length > 0) {
          this.detailCover = this.client.abs(this.detailTracks[i].cover); break;
        }
      }
    } catch (e) {
      // Keep cached rows visible even when the server detail request fails.
      if (this.detailTracks.length === 0) this.detailTracks = this.remotePlaylistFallbackTracks(p);
      this.setToast(CLOUD_OFFLINE_MESSAGE);
    }
  }

  async loadLib(i: number): Promise<void> {
    this.lib = i;
    this.page = 'main';
    try {
      if (i === 0) {
        this.songs = await this.client.songs();
        await this.loadPlaylistCache();
        this.applyPlaylistCacheState();
      } else if (i === 1) {
        this.albums = await this.client.albums();
      } else if (i === 2) {
        this.artists = await this.client.artists();
      } else if (i === 3) {
        this.playlists = await this.client.playlists();
        await this.loadPlaylistCache();
        this.applyPlaylistCacheState();
      } else if (i === 4) {
        this.liked = await this.client.liked();
        try { this.sources = await this.client.sources(); } catch (_e) {}
        try { this.songs = await this.client.songs(); } catch (_e) {}
        await this.loadPlaylistCache();
        this.applyPlaylistCacheState();
      } else if (i === 5) {
        this.recent = await this.client.recentAlbums();
      } else if (i === 6 && this.radioEnabled) {
        this.radios = await this.client.radios();
      }
    } catch (e) {
      this.err = '' + e;
    }
    if (i === 0 || i === 3 || i === 4) {
      await this.loadPlaylistCache();
      await this.mergeOfflineMetadataSnapshot();
      this.syncNasFavoriteCacheFromServer();
      this.upsertSongIndexFromTracks(this.songs);
      await this.savePlaylistCache();
      this.applyPlaylistCacheState();
    }
  }

  async doSearch(): Promise<void> {
    await this.commitSearch(this.q);
  }

  repeatLabel(): string {
    if (this.repeat === 1) return '列表循环';
    if (this.repeat === 2) return '单曲循环';
    if (this.repeat === 3) return '顺序播放';
    return '随机播放';
  }


  waveSampleHeight(index: number): number {
    if (!this.playing) {
      const idle: number[] = [6, 10, 14, 10, 6];
      return idle[index % idle.length];
    }
    // 把 5 根音柱理解为对一条移动正弦波的 5 个采样点：相位连续移动，柱高跟随采样值变化。
    const phase = this.wavePulse * Math.PI;
    const sample = Math.sin(index * 1.16 + phase);
    return 5.5 + (sample + 1) * 5.2;
  }



  cardW(): number {
    const per = this.wide() ? 4 : 2;
    return (this.screenW - this.mg() * 2 - 12) / per;
  }

  heroGridH(): number {
    if (this.newest.length === 0) {
      return 0;
    }
    const per = this.wide() ? 4 : 2;
    const rows = Math.ceil(this.newest.length / per);
    const cell = this.cardW() + 48;
    return rows * cell + (rows - 1) * 12 + 6;
  }

  homeCollapseK(): number {
    return Math.max(0, Math.min(1, this.homeScrollY / 150));
  }











  followedArtistRows(): Artist[] {
    const rows: Artist[] = [];
    for (let i = 0; i < this.artists.length; i++) {
      const a = this.artists[i];
      if (this.isArtistFollowed(a.source, a.id, a.name)) rows.push(a);
    }
    return rows;
  }





  searchSuggestionMatchIndex(value: string): number {
    const key = this.q.trim().toLowerCase();
    if (key.length === 0) return -1;
    return value.toLowerCase().indexOf(key);
  }

  searchSuggestionKeyLength(): number {
    return this.q.trim().length;
  }










  px(v: number): number {
    return v * this.density;
  }

  mg(): number {
    return Math.min(24, Math.max(12, this.screenW * 0.042));
  }

  mg1(): number {
    return this.mg() * 1.5;
  }

  // 二级页统一内容宽度。不要再使用 width('100%') + 左右 margin，
  // 否则 ArkUI 会把 margin 叠加到 100% 宽度之外，造成右侧控件裁切。
  contentW(): number {
    return Math.max(240, this.screenW - this.mg() * 2);
  }

  hdsMiniBarContentWidth(): number {
    if (this.screenW >= 840) return 328;
    if (this.screenW >= 600) return 284;
    return Math.max(264, this.screenW - 96);
  }

  hdsMiniBarTextWidth(): number {
    return Math.max(64, this.hdsMiniBarContentWidth() - 212);
  }

  iconCardArtSize(): number {
    return Math.min(126, Math.max(88, (this.contentW() - 10) / 2 - 26));
  }










    heartP(s: number): string {
    const k: number = this.density;
    return `M${0.5 * s * k} ${0.85 * s * k} C${0.27 * s * k} ${0.69 * s * k} ${0.12 * s * k} ${0.54 * s * k} ${0.12 * s * k} ${0.38 * s * k} ` +
      `C${0.12 * s * k} ${0.255 * s * k} ${0.215 * s * k} ${0.16 * s * k} ${0.33 * s * k} ${0.16 * s * k} ` +
      `C${0.41 * s * k} ${0.16 * s * k} ${0.465 * s * k} ${0.21 * s * k} ${0.5 * s * k} ${0.275 * s * k} ` +
      `C${0.535 * s * k} ${0.21 * s * k} ${0.59 * s * k} ${0.16 * s * k} ${0.67 * s * k} ${0.16 * s * k} ` +
      `C${0.785 * s * k} ${0.16 * s * k} ${0.88 * s * k} ${0.255 * s * k} ${0.88 * s * k} ${0.38 * s * k} ` +
      `C${0.88 * s * k} ${0.54 * s * k} ${0.73 * s * k} ${0.69 * s * k} ${0.5 * s * k} ${0.85 * s * k} Z`;
  }






  skipGlyph(box: number): number {
    return box < 48 ? 12 : 14;
  }




  // 播放器也严格服从全局主题：深色纯白，浅色纯黑。
  playerInk(): string {
    return this.themeInk();
  }

  playerInk2(): string {
    return this.themeInk();
  }

  playerTrack(): string {
    return this.themeInkTrack();
  }

  playerModeAccent(): string {
    return this.themeInk();
  }

  playerModeBg(): string {
    return this.isDark ? this.moodDeep : mixHex(this.moodSoft, '#FAFAFC', 0.82);
  }

  ambBottom(): string {
    return this.isDark ? mixHex(this.moodSoft, '#000000', 0.06) : mixHex(this.moodGlow, '#FFFFFF', 0.62);
  }

  blockLyricSeek(ms: number = 700): void {
    const until = Date.now() + ms;
    if (until > this.lyricSeekBlockUntil) {
      this.lyricSeekBlockUntil = until;
    }
  }

  canSeekFromLyric(): boolean {
    const now = Date.now();
    return now >= this.lyricSeekBlockUntil && now - this.lastPageSwitch > 500;
  }

  setPage(pg: number): void {
    if (pg < 0 || pg > 1 || pg === this.nowPage) {
      return;
    }
    this.lastPageSwitch = Date.now();
    this.resetIdle();
    this.getUIContext().animateTo({ duration: 480, curve: Curve.Friction }, () => {
      this.nowPage = pg;
    });
    if (pg === 1 && this.lyLines.length === 0) {
      const t = this.current();
      if (t !== undefined) {
        this.loadLyrics(t);
      }
    }
  }

  span(t: number, a: number, b: number): number {
    const u = (t - a) / (b - a);
    if (u <= 0) {
      return 0;
    }
    if (u >= 1) {
      return 1;
    }
    return u;
  }

  easeIn(t: number, a: number, b: number): number {
    const u = this.span(t, a, b);
    return u * u * (3 - 2 * u);
  }

  softShow(t: number): number {
    if (t <= 0) {
      return 0;
    }
    if (t >= 1) {
      return 1;
    }
    return Math.pow(t, 0.52);
  }

  fullOp(): number {
    return this.expand;
  }

  playerMetaTid(): string {
    return 'meow-now-playing-meta';
  }

  playerH(): number {
    return this.screenH;
  }

  dockBottom(): number {
    return 0;
  }

  flyPlay(): number {
    return 44;
  }


  playerBackdropTop(): string {
    return this.isDark ? mixHex(this.moodGlow, '#060608', 0.54) : mixHex(this.moodGlow, '#FFFFFF', 0.64);
  }

  playerBackdropMid(): string {
    return this.isDark ? mixHex(this.moodSoft, '#09090B', 0.42) : mixHex(this.moodSoft, '#FAFAFC', 0.72);
  }

  playerBackdropBottom(): string {
    return this.isDark ? mixHex(this.moodDeep, '#000000', 0.58) : mixHex(this.moodDeep, '#F5F5F8', 0.84);
  }







  curQualityText(): string {
    const t = this.current();
    if (t === undefined) {
      return '';
    }
    const q = this.qIndex === 0 ? '原曲' : Q_NAME[this.qIndex];
    return q + ' · ' + t.album;
  }

  cycleRepeat(): void {
    this.repeat = (this.repeat + 1) % 4;
    this.setToast(this.repeatLabel());
    this.updateSessionState();
    this.lvSync();
  }







  tabClr(i: number): string {
    return this.tab === i ? this.uiTheme.text : this.uiTheme.sub;
  }


  onHdsTabChange(index: number): void {
    if (index === this.tab && this.page === 'main') {
      return;
    }
    this.tab = index;
    if (index === 0) {
      const offset = this.homePageScroller.offset();
      this.homeScrollY = offset !== undefined ? Math.max(0, Math.min(240, offset.yOffset)) : 0;
    }
    this.page = 'main';
    if (index === 1) {
      this.loadLib(this.lib);
    }
    if (index === 3) {
      this.loadMe();
    }
  }










  resetStandaloneScroll(): void {
    setTimeout(() => {
      try {
        this.standalonePageScroller.scrollEdge(Edge.Top);
      } catch (_e) {
      }
    }, 24);
  }

  standalonePageTitle(): string {
    if (this.page === 'settings') return '设置';
    if (this.page === 'advanced') return '高级设置';
    if (this.page === 'icons') return '应用图标';
    if (this.page === 'stats') return '听歌统计';
    if (this.page === 'local') return '本地音乐';
    if (this.page === 'downloads') return '下载管理';
    if (this.page === 'liked') return '收藏';
    if (this.page === 'recent') return '最近播放';
    if (this.page === 'followed') return '关注';
    return '';
  }


  openSettingsPage(): void {
    this.page = 'settings';
    this.loadSources();
    this.resetStandaloneScroll();
  }

  openIconSettingsPage(): void {
    this.page = 'icons';
    this.loadAppIconPrefs();
    this.resetStandaloneScroll();
  }

  openAdvancedSettingsPage(): void {
    this.page = 'advanced';
    this.refreshCacheInfo();
    this.resetStandaloneScroll();
  }

  isStandalonePage(): boolean {
    return this.page === 'settings' || this.page === 'icons' || this.page === 'advanced' ||
      this.page === 'stats' || this.page === 'local' || this.page === 'downloads' || this.page === 'liked' ||
      this.page === 'recent' || this.page === 'followed';
  }

  standaloneShowsMiniBar(): boolean {
    // 内容型二级页面保持全局播放入口；设置/图标/高级设置属于纯配置页，不覆盖播放条。
    return this.page === 'local' || this.page === 'downloads' || this.page === 'liked' || this.page === 'recent' ||
      this.page === 'followed' || this.page === 'stats';
  }

  // Open-source reference UI state. These fields are intentionally plain and contain no production animation/design logic.
  @State coreDetailVisible: boolean = false;
  @State corePlayerVisible: boolean = false;
  @State coreQueueVisible: boolean = false;
  @State coreSearchKind: number = 0;

  coreBg(): string { return this.isDark ? '#111111' : '#FFFFFF'; }
  coreCard(): string { return this.isDark ? '#202020' : '#F2F2F2'; }
  coreText(): string { return this.isDark ? '#FFFFFF' : '#111111'; }
  coreSub(): string { return this.isDark ? '#B8B8B8' : '#666666'; }
  coreAccent(): string { return this.isDark ? '#FFFFFF' : '#111111'; }

  coreSelectTab(index: number): void {
    this.tab = index;
    this.page = 'main';
    this.coreDetailVisible = false;
    this.corePlayerVisible = false;
    this.coreQueueVisible = false;
    if (index === 1) this.loadLib(this.lib);
    if (index === 3) this.loadMe();
  }

  coreOpenAlbum(a: Album): void {
    this.coreDetailVisible = true;
    this.corePlayerVisible = false;
    this.openAlbum(a);
  }

  coreOpenArtist(a: Artist): void {
    this.coreDetailVisible = true;
    this.corePlayerVisible = false;
    this.openArtist(a);
  }

  coreOpenPlaylist(p: Playlist): void {
    this.coreDetailVisible = true;
    this.corePlayerVisible = false;
    this.openPlaylist(p);
  }

  coreCloseDetail(): void {
    this.detailLoadToken++;
    this.coreDetailVisible = false;
  }

  coreOpenCurrentArtist(): void {
    this.coreDetailVisible = true;
    this.corePlayerVisible = false;
    this.openNowArtist();
  }

  coreOpenCurrentAlbum(): void {
    this.coreDetailVisible = true;
    this.corePlayerVisible = false;
    this.openNowAlbum();
  }

  coreSelectSourceKind(kind: string): void {
    if (this.srcBusy) return;
    this.srcKind = kind === 'webdav' ? 'webdav' : 'subsonic';
    if (this.srcEditId.length === 0 && (this.srcName.length === 0 || this.srcName === 'Navidrome' || this.srcName === 'WebDAV')) {
      this.srcName = this.srcKind === 'webdav' ? 'WebDAV' : 'Navidrome';
    }
    this.srcOk = false;
    this.srcMsg = '';
  }

  coreNewSource(): void {
    this.srcEditId = '';
    this.srcName = this.srcKind === 'webdav' ? 'WebDAV' : 'Navidrome';
    this.srcUrl = '';
    this.srcUser = '';
    this.srcPass = '';
    this.srcMsg = '';
    this.srcOk = false;
  }

  coreQueuePlay(index: number): void {
    if (index < 0 || index >= this.queue.length) return;
    this.qpos = index;
    this.playCurrent();
  }

  coreQueueRemove(index: number): void {
    if (index < 0 || index >= this.queue.length) return;
    const next: Track[] = [];
    for (let i = 0; i < this.queue.length; i++) if (i !== index) next.push(this.queue[i]);
    if (next.length === 0) {
      this.queue = [];
      this.qpos = 0;
      this.playing = false;
      return;
    }
    if (index < this.qpos) this.qpos--;
    else if (index === this.qpos && this.qpos >= next.length) this.qpos = next.length - 1;
    this.queue = next;
    this.saveQueueState();
  }

  coreAddTrackToPlaylist(t: Track): void {
    this.plPickTrack = t;
    this.plPickTitle = t.title;
    this.plPickOn = true;
  }

  @Builder
  coreNavButton(label: string, selected: boolean, action: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .fontSize(14)
      .height(40)
      .fontColor(selected ? this.coreBg() : this.coreText())
      .backgroundColor(selected ? this.coreAccent() : this.coreCard())
      .onClick(action)
  }

  @Builder
  coreHeader(title: string, back: () => void) {
    Row({ space: 10 }) {
      Button('返回').type(ButtonType.Normal).onClick(back)
      Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.coreText()).layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  @Builder
  coreStatus() {
    if (this.err.length > 0) {
      Row({ space: 8 }) {
        Text(this.err).fontSize(12).fontColor('#E33').layoutWeight(1).maxLines(2)
        Button('重试').type(ButtonType.Normal).onClick(() => { this.retrySources(); })
      }
      .width('100%').padding({ left: 12, right: 12, bottom: 6 })
    } else if (this.toast.length > 0 || this.offlineHint.length > 0) {
      Text(this.toast.length > 0 ? this.toast : this.offlineHint)
        .fontSize(12).fontColor(this.coreSub()).width('100%')
        .padding({ left: 12, right: 12, bottom: 6 }).maxLines(2)
    }
  }

  @Builder
  coreTrackRow(t: Track, rows: Track[], index: number) {
    Row({ space: 8 }) {
      Column() {
        Text(t.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.coreText()).maxLines(1)
        Text(t.artist + (t.album.length > 0 ? ' · ' + t.album : '') + (t.duration > 0 ? ' · ' + fmtDur(t.duration) : ''))
          .fontSize(11).fontColor(this.coreSub()).maxLines(1)
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('播放').type(ButtonType.Normal).fontSize(12).onClick(() => { this.playList(rows, index); })
      Button(this.isCachedFavorite(this.trackRef(t)) ? '已收藏' : '收藏')
        .type(ButtonType.Normal).fontSize(12).onClick(() => { this.likeTrack(t); })
      Button('歌单').type(ButtonType.Normal).fontSize(12).onClick(() => { this.coreAddTrackToPlaylist(t); })
    }
    .width('100%').padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#DDDDDD' })
  }

  @Builder
  coreTrackList(rows: Track[]) {
    List() {
      ForEach(rows, (t: Track, index: number) => {
        ListItem() { this.coreTrackRow(t, rows, index) }
      }, (t: Track, index: number) => t.source + '/' + t.id + '/' + index)
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  coreAlbumList(rows: Album[]) {
    List() {
      ForEach(rows, (a: Album) => {
        ListItem() {
          Row({ space: 10 }) {
            if (a.cover.length > 0) {
              Image(this.client.abs(a.cover)).width(48).height(48).objectFit(ImageFit.Cover).borderRadius(6)
            }
            Column() {
              Text(a.title).fontSize(15).fontColor(this.coreText()).maxLines(1)
              Text(a.artist + (a.year > 0 ? ' · ' + a.year : '')).fontSize(11).fontColor(this.coreSub()).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('详情').type(ButtonType.Normal).onClick(() => { this.coreOpenAlbum(a); })
          }
          .width('100%').padding(10)
        }
      }, (a: Album) => a.source + '/' + a.id)
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  coreArtistList(rows: Artist[]) {
    List() {
      ForEach(rows, (a: Artist) => {
        ListItem() {
          Row({ space: 10 }) {
            if (a.cover.length > 0) {
              Image(this.client.abs(a.cover)).width(44).height(44).objectFit(ImageFit.Cover).borderRadius(22)
            }
            Column() {
              Text(a.name).fontSize(15).fontColor(this.coreText()).maxLines(1)
              Text(a.albumCount + ' 张专辑').fontSize(11).fontColor(this.coreSub())
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('详情').type(ButtonType.Normal).onClick(() => { this.coreOpenArtist(a); })
          }.width('100%').padding(10)
        }
      }, (a: Artist) => a.source + '/' + a.id)
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  corePlaylistList(rows: Playlist[]) {
    List() {
      ListItem() {
        Row({ space: 8 }) {
          Button('新建歌单').type(ButtonType.Normal).onClick(() => { this.plDlgMode = 1; this.plDlgName = ''; })
          Button('导入分享码').type(ButtonType.Normal).onClick(() => { this.importOpen = true; this.importCode = ''; })
        }.width('100%').padding(10)
      }
      ForEach(rows, (p: Playlist) => {
        ListItem() {
          Row({ space: 8 }) {
            Column() {
              Text(p.name).fontSize(15).fontColor(this.coreText()).maxLines(1)
              Text(p.songCount + ' 首' + (p.available === false ? ' · 离线缓存' : '')).fontSize(11).fontColor(this.coreSub())
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('播放').type(ButtonType.Normal).onClick(() => { this.playPlaylistNow(p); })
            Button('详情').type(ButtonType.Normal).onClick(() => { this.coreOpenPlaylist(p); })
            Button('管理').type(ButtonType.Normal).onClick(() => { this.openManage(p); })
          }.width('100%').padding(10)
        }
      }, (p: Playlist) => p.source + '/' + p.id)
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  coreRadioList() {
    List() {
      ForEach(this.radios, (r: InternetRadio) => {
        ListItem() {
          Row() {
            Column() {
              Text(r.name).fontSize(15).fontColor(this.coreText())
              Text(r.homepageUrl).fontSize(10).fontColor(this.coreSub()).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('播放').type(ButtonType.Normal).onClick(() => { this.playRadio(r); })
          }.width('100%').padding(10)
        }
      }, (r: InternetRadio) => r.source + '/' + r.id)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreMiniPlayer() {
    Column() {
      Slider({ value: this.pos, min: 0, max: this.dur > 0 ? this.dur : 1, step: 1 })
        .width('100%').onChange((v: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.seekTo(v);
        })
      Row({ space: 8 }) {
        Column() {
          Text(this.nowTitle).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.coreText()).maxLines(1)
          Text(this.nowArtist).fontSize(11).fontColor(this.coreSub()).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => { this.corePlayerVisible = true; })
        Button('上一首').type(ButtonType.Normal).onClick(() => { this.prev(); })
        Button(this.playing ? '暂停' : '播放').type(ButtonType.Normal).onClick(() => { this.toggle(); })
        Button('下一首').type(ButtonType.Normal).onClick(() => { this.next(true); })
        Button('队列').type(ButtonType.Normal).onClick(() => { this.coreQueueVisible = true; })
      }.width('100%').padding({ left: 10, right: 10, bottom: 8 })
    }.width('100%').backgroundColor(this.coreCard())
  }

  @Builder
  coreHomePage() {
    Scroll() {
      Column({ space: 10 }) {
        Row() {
          Text('首页').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.coreText()).layoutWeight(1)
          Button('刷新').type(ButtonType.Normal).onClick(() => { this.refreshHomeFromServer(); })
        }.width('100%')
        Text('推荐歌曲').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%')
        ForEach(this.homeFeedSongs().slice(0, 12), (t: Track, i: number) => { this.coreTrackRow(t, this.homeFeedSongs(), i) },
          (t: Track, i: number) => 'home/' + t.source + '/' + t.id + '/' + i)
        Text('最近专辑').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 8 })
        ForEach(this.recent.slice(0, 10), (a: Album) => {
          Row() {
            Text(a.title + ' · ' + a.artist).fontSize(14).fontColor(this.coreText()).layoutWeight(1).maxLines(1)
            Button('详情').type(ButtonType.Normal).onClick(() => { this.coreOpenAlbum(a); })
          }.width('100%').padding({ top: 6, bottom: 6 })
        }, (a: Album) => 'recent/' + a.source + '/' + a.id)
        Text('最新专辑').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 8 })
        ForEach(this.newest.slice(0, 10), (a: Album) => {
          Row() {
            Text(a.title + ' · ' + a.artist).fontSize(14).fontColor(this.coreText()).layoutWeight(1).maxLines(1)
            Button('详情').type(ButtonType.Normal).onClick(() => { this.coreOpenAlbum(a); })
          }.width('100%').padding({ top: 6, bottom: 6 })
        }, (a: Album) => 'new/' + a.source + '/' + a.id)
        Column().height(20)
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreLibraryPage() {
    Column() {
      Text('资料库').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').padding({ left: 12, top: 8, bottom: 8 })
      Scroll() {
        Row({ space: 6 }) {
          this.coreNavButton('歌曲', this.lib === 0, () => { this.loadLib(0); })
          this.coreNavButton('专辑', this.lib === 1, () => { this.loadLib(1); })
          this.coreNavButton('歌手', this.lib === 2, () => { this.loadLib(2); })
          this.coreNavButton('歌单', this.lib === 3, () => { this.loadLib(3); })
          this.coreNavButton('收藏', this.lib === 4, () => { this.loadLib(4); })
          this.coreNavButton('最近', this.lib === 5, () => { this.loadLib(5); })
          if (this.radioEnabled) this.coreNavButton('电台', this.lib === 6, () => { this.loadLib(6); })
        }.padding({ left: 10, right: 10, bottom: 8 })
      }.scrollable(ScrollDirection.Horizontal).width('100%')
      if (this.lib === 0) this.coreTrackList(this.songs)
      else if (this.lib === 1) this.coreAlbumList(this.albums)
      else if (this.lib === 2) this.coreArtistList(this.artists)
      else if (this.lib === 3) this.corePlaylistList(this.playlists)
      else if (this.lib === 4) this.coreTrackList(this.liked)
      else if (this.lib === 5) this.coreAlbumList(this.recent)
      else this.coreRadioList()
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreSearchPage() {
    Column() {
      Text('搜索').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').padding({ left: 12, top: 8, bottom: 8 })
      Row({ space: 8 }) {
        TextInput({ text: this.q, placeholder: '歌名 / 歌手 / 专辑', controller: this.searchInputController })
          .layoutWeight(1).onChange((v: string) => { this.scheduleSearchSuggestion(v); }).onSubmit(() => { this.doSearch(); })
        Button('搜索').type(ButtonType.Normal).onClick(() => { this.doSearch(); })
      }.width('100%').padding({ left: 10, right: 10 })
      if (!this.searchCommitted && this.q.trim().length > 0 && this.searchSuggestions.length > 0) {
        List() {
          ForEach(this.searchSuggestions.slice(0, 12), (s: string) => {
            ListItem() {
              Button(s).type(ButtonType.Normal).width('100%').fontColor(this.coreText()).backgroundColor(this.coreCard())
                .onClick(() => { this.commitSearch(s); })
            }
          }, (s: string) => 'sug/' + s)
        }.height(Math.min(300, this.searchSuggestions.length * 44)).width('100%').padding({ left: 10, right: 10 })
      } else if (!this.searchCommitted && this.q.trim().length === 0 && this.searchHistory.length > 0) {
        Row() {
          Text('历史记录').fontSize(13).fontColor(this.coreSub()).layoutWeight(1)
          Button('清空').type(ButtonType.Normal).onClick(() => { this.clearSearchHistory(); })
        }.width('100%').padding({ left: 10, right: 10, top: 6 })
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.searchHistory.slice(0, 12), (s: string) => {
              Button(s).type(ButtonType.Normal).onClick(() => { this.commitSearch(s); })
            }, (s: string) => 'hist/' + s)
          }.padding({ left: 10, right: 10, bottom: 8 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }
      if (this.searchCommitted) {
        Row({ space: 6 }) {
          this.coreNavButton('歌曲 ' + this.hitSongs.length, this.coreSearchKind === 0, () => { this.coreSearchKind = 0; })
          this.coreNavButton('专辑 ' + this.hitAlbums.length, this.coreSearchKind === 1, () => { this.coreSearchKind = 1; })
          this.coreNavButton('歌手 ' + this.hitArtists.length, this.coreSearchKind === 2, () => { this.coreSearchKind = 2; })
        }.width('100%').padding(10)
        if (this.coreSearchKind === 0) this.coreTrackList(this.hitSongs)
        else if (this.coreSearchKind === 1) this.coreAlbumList(this.hitAlbums)
        else this.coreArtistList(this.hitArtists)
      } else {
        Column().layoutWeight(1)
      }
    }.width('100%').layoutWeight(1)
  }

  async coreOpenLikedPage(): Promise<void> {
    await this.loadLib(4);
    this.page = 'liked';
  }

  async coreOpenRecentPage(): Promise<void> {
    await this.loadLib(5);
    this.page = 'recent';
  }

  @Builder
  coreMePage() {
    Scroll() {
      Column({ space: 8 }) {
        Text('我的').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%')
        Text(this.accountName() + ' · ' + this.sourceModeLabel()).fontSize(12).fontColor(this.coreSub()).width('100%')
        Button('收藏 ' + this.liked.length).width('100%').onClick(() => { this.coreOpenLikedPage(); })
        Button('最近播放').width('100%').onClick(() => { this.coreOpenRecentPage(); })
        Button('关注的歌手 ' + this.followedArtistRows().length).width('100%').onClick(() => { this.page = 'followed'; })
        Button('本地音乐 ' + this.localSongs.length).width('100%').onClick(() => { this.page = 'local'; this.scanLocalLibrary(); })
        Button('下载管理 ' + this.downloadedLocalRows().length).width('100%').onClick(() => { this.page = 'downloads'; this.scanLocalLibrary(); })
        Button('听歌统计').width('100%').onClick(() => { this.page = 'stats'; })
        Button('设置 / 音源').width('100%').onClick(() => { this.page = 'settings'; this.loadSources(); })
        Button('高级设置').width('100%').onClick(() => { this.page = 'advanced'; this.refreshCacheInfo(); })
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreDetailPage() {
    Column() {
      this.coreHeader('详情', () => { this.coreCloseDetail(); })
      Column({ space: 8 }) {
        if (this.detailCover.length > 0) {
          Image(this.detailCover).width(160).height(160).objectFit(ImageFit.Cover).borderRadius(8)
        }
        Text(this.detailTitle).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.coreText()).maxLines(2)
        Text(this.detailSub).fontSize(13).fontColor(this.coreSub()).maxLines(2)
        Row({ space: 8 }) {
          if (this.detailTracks.length > 0) Button('播放全部').onClick(() => { this.playList(this.detailTracks, 0); })
          if (this.detailKind === 'artist') {
            Button(this.isArtistFollowed(this.detailSource, this.detailId, this.detailTitle) ? '取消关注' : '关注')
              .onClick(() => { this.toggleDetailArtistFollow(); })
          }
        }
      }.width('100%').padding({ left: 12, right: 12, bottom: 10 }).alignItems(HorizontalAlign.Start)
      if (this.detailKind === 'artist' && this.artistAlbums.length > 0) {
        Text('专辑').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').padding({ left: 12, bottom: 6 })
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.artistAlbums, (a: Album) => { Button(a.title).type(ButtonType.Normal).onClick(() => { this.coreOpenAlbum(a); }) },
              (a: Album) => 'artistalbum/' + a.source + '/' + a.id)
          }.padding({ left: 10, right: 10, bottom: 6 })
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }
      this.coreTrackList(this.detailTracks)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreQueuePage() {
    Column() {
      this.coreHeader('播放队列', () => { this.coreQueueVisible = false; })
      List() {
        ForEach(this.queue, (t: Track, i: number) => {
          ListItem() {
            Row({ space: 8 }) {
              Text((i === this.qpos ? '▶ ' : '') + t.title + ' · ' + t.artist).fontSize(14).fontColor(this.coreText()).layoutWeight(1).maxLines(1)
              Button('播放').type(ButtonType.Normal).onClick(() => { this.coreQueuePlay(i); })
              Button('移除').type(ButtonType.Normal).onClick(() => { this.coreQueueRemove(i); })
            }.width('100%').padding(10)
          }
        }, (t: Track, i: number) => 'queue/' + i + '/' + t.source + '/' + t.id)
      }.width('100%').layoutWeight(1)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  corePlayerPage() {
    Scroll() {
      Column({ space: 10 }) {
        Row() {
          Button('返回').onClick(() => { this.corePlayerVisible = false; })
          Text('正在播放').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.coreText()).layoutWeight(1)
          Button('队列').onClick(() => { this.coreQueueVisible = true; })
        }.width('100%')
        if (this.nowCover.length > 0) Image(this.nowCover).width(220).height(220).objectFit(ImageFit.Cover).borderRadius(8)
        Text(this.nowTitle).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.coreText()).maxLines(2)
        Text(this.nowArtist).fontSize(14).fontColor(this.coreSub()).maxLines(1)
        Slider({ value: this.pos, min: 0, max: this.dur > 0 ? this.dur : 1, step: 1 })
          .width('100%').onChange((v: number, mode: SliderChangeMode) => { if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.seekTo(v); })
        Text(fmtDur(this.pos) + ' / ' + fmtDur(this.dur)).fontSize(12).fontColor(this.coreSub())
        Row({ space: 8 }) {
          Button('上一首').onClick(() => { this.prev(); })
          Button(this.playing ? '暂停' : '播放').onClick(() => { this.toggle(); })
          Button('下一首').onClick(() => { this.next(true); })
        }
        Row({ space: 6 }) {
          Button(this.repeatLabel()).onClick(() => { this.cycleRepeat(); })
          Button(this.nowLiked ? '取消收藏' : '收藏').onClick(() => { this.like(); })
          Button('下载').onClick(() => { this.downloadNow(); })
          Button(this.curQualityText()).onClick(() => { this.pickQuality((this.qIndex + 1) % Q_NAME.length); })
        }
        Row({ space: 6 }) {
          Button('歌手').onClick(() => { this.coreOpenCurrentArtist(); })
          Button('专辑').onClick(() => { this.coreOpenCurrentAlbum(); })
          Button('相似歌曲').onClick(() => { this.similarNow(); })
          Button('加入歌单').onClick(() => { const t = this.current(); if (t !== undefined) this.coreAddTrackToPlaylist(t); })
        }
        Row({ space: 6 }) {
          Button('分享').onClick(() => { this.shareNow(); })
          Button('复制信息').onClick(() => { this.copyNow(); })
          Button('15 分钟').onClick(() => { this.setSleepMinutes(15); })
          Button('30 分钟').onClick(() => { this.setSleepMinutes(30); })
          Button('关闭定时').onClick(() => { this.setSleepMinutes(0); })
        }
        Text('睡眠定时：' + this.sleepLabel()).fontSize(12).fontColor(this.coreSub()).width('100%')
        Text('歌词').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 8 })
        if (this.lyLines.length === 0) {
          Text(this.lyricsStatus.length > 0 ? this.lyricsStatus : '暂无歌词').fontSize(13).fontColor(this.coreSub()).width('100%')
        } else {
          ForEach(this.lyLines, (l: LyricLine, i: number) => {
            Text(l.line).fontSize(i === this.lyIndex ? 18 : 14).fontWeight(i === this.lyIndex ? FontWeight.Bold : FontWeight.Regular)
              .fontColor(i === this.lyIndex ? this.coreText() : this.coreSub()).width('100%').padding({ top: 5, bottom: 5 })
              .onClick(() => { this.seekTo(l.t); })
          }, (l: LyricLine, i: number) => 'ly/' + i + '/' + l.t)
        }
        Column().height(24)
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreSettingsPage() {
    Scroll() {
      Column({ space: 10 }) {
        this.coreHeader('设置 / 音源', () => { this.page = 'main'; })
        Text('音乐源模式').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%')
        Row({ space: 6 }) {
          this.coreNavButton('仅 NAS', this.musicSourceMode === 0, () => { this.setMusicSourceMode(0); })
          this.coreNavButton('仅 WebDAV', this.musicSourceMode === 1, () => { this.setMusicSourceMode(1); })
          this.coreNavButton('合并', this.musicSourceMode === 2, () => { this.setMusicSourceMode(2); })
        }.width('100%')
        Text('已配置音源').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 8 })
        ForEach(this.sources, (s: SourceRow) => {
          Row({ space: 8 }) {
            Column() {
              Text(s.name).fontSize(14).fontColor(this.coreText()).maxLines(1)
              Text(this.sourceTypeLabel(s.type) + ' · ' + (s.online ? '在线' : '离线') + ' · ' + (s.url !== undefined ? s.url : ''))
                .fontSize(10).fontColor(this.coreSub()).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('编辑').onClick(() => { this.editSource(s.id); })
            Button('删除').onClick(() => { this.removeSource(s.id); })
          }.width('100%').padding(8).backgroundColor(this.coreCard())
        }, (s: SourceRow) => 'source/' + s.id)
        Row() {
          Text(this.srcEditId.length > 0 ? '编辑音源' : '添加音源').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).layoutWeight(1)
          Button('清空').onClick(() => { this.coreNewSource(); })
        }.width('100%').margin({ top: 8 })
        Row({ space: 6 }) {
          this.coreNavButton('Navidrome', this.srcKind === 'subsonic', () => { this.coreSelectSourceKind('subsonic'); })
          this.coreNavButton('WebDAV', this.srcKind === 'webdav', () => { this.coreSelectSourceKind('webdav'); })
        }.width('100%')
        TextInput({ text: this.srcName, placeholder: '名称' }).onChange((v: string) => { this.srcName = v; })
        TextInput({ text: this.srcUrl, placeholder: this.srcKind === 'webdav' ? 'WebDAV 地址，例如 http://nas:5244/dav/' : 'Navidrome 地址' })
          .onChange((v: string) => { this.srcUrl = v; })
        TextInput({ text: this.srcUser, placeholder: '用户名' }).onChange((v: string) => { this.srcUser = v; })
        TextInput({ text: this.srcPass, placeholder: '密码' }).type(InputType.Password).onChange((v: string) => { this.srcPass = v; })
        if (this.srcMsg.length > 0) Text(this.srcMsg).fontSize(12).fontColor(this.srcOk ? '#2A9D42' : '#D33').width('100%')
        Row({ space: 8 }) {
          Button(this.srcBusy ? '处理中…' : '测试连接').enabled(!this.srcBusy).onClick(() => { this.probeSource(); })
          Button(this.srcBusy ? '处理中…' : (this.srcEditId.length > 0 ? '保存修改' : '保存')).enabled(!this.srcBusy).onClick(() => { this.addSource(); })
        }
        Text('歌单 / 收藏离线缓存：' + this.playlistCacheSummary()).fontSize(12).fontColor(this.coreSub()).width('100%').margin({ top: 8 })
        Button('清理歌单缓存').onClick(() => { this.clearPlaylistCache(); })
        Column().height(20)
      }.width('100%').padding({ left: 12, right: 12 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreAdvancedPage() {
    Scroll() {
      Column({ space: 8 }) {
        this.coreHeader('高级设置', () => { this.page = 'main'; })
        Text('播放').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%')
        Toggle({ type: ToggleType.Switch, isOn: this.continueLast }).onChange((v: boolean) => { this.setAdvancedBool('continueLast', v); })
        Text('继续上次播放：' + (this.continueLast ? '开' : '关')).fontColor(this.coreText())
        Toggle({ type: ToggleType.Switch, isOn: this.coexistAudio }).onChange((v: boolean) => { this.setAdvancedBool('coexistAudio', v); })
        Text('与其他应用同时播放：' + (this.coexistAudio ? '开' : '关')).fontColor(this.coreText())
        Toggle({ type: ToggleType.Switch, isOn: this.replayGain }).onChange((v: boolean) => { this.setAdvancedBool('replayGain', v); })
        Text('ReplayGain：' + (this.replayGain ? '开' : '关')).fontColor(this.coreText())
        Toggle({ type: ToggleType.Switch, isOn: this.fadeAudio }).onChange((v: boolean) => { this.setAdvancedBool('fadeAudio', v); })
        Text('淡入淡出：' + (this.fadeAudio ? '开' : '关')).fontColor(this.coreText())
        Toggle({ type: ToggleType.Switch, isOn: this.forceKaraoke }).onChange((v: boolean) => { this.setAdvancedBool('forceKaraoke', v); })
        Text('强制逐字歌词：' + (this.forceKaraoke ? '开' : '关')).fontColor(this.coreText())
        Text('界面 / 歌词').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 10 })
        Row({ space: 6 }) {
          Button('歌词字号：' + this.lyricSizeLabel()).onClick(() => { this.cycleLyricSize(); })
          Button('界面字号：' + this.interfaceSizeLabel()).onClick(() => { this.cycleInterfaceSize(); })
          Button('主题：' + this.themeLabel()).onClick(() => { this.cycleTheme(); })
        }
        Toggle({ type: ToggleType.Switch, isOn: this.carLyrics }).onChange((v: boolean) => { this.setAdvancedBool('carLyrics', v); })
        Text('车载 / 蓝牙歌词：' + (this.carLyrics ? '开' : '关')).fontColor(this.coreText())
        Toggle({ type: ToggleType.Switch, isOn: this.radioEnabled }).onChange((v: boolean) => { this.setAdvancedBool('radioEnabled', v); })
        Text('网络电台：' + (this.radioEnabled ? '开' : '关')).fontColor(this.coreText())
        Text('加载限制').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 10 })
        Row({ space: 6 }) {
          Button('歌曲 ' + this.songLoadLimit).onClick(() => { this.cycleSongLoadLimit(); })
          Button('专辑 ' + this.albumLoadLimit).onClick(() => { this.cycleAlbumLoadLimit(); })
          Button('歌手 ' + this.artistLoadLimit).onClick(() => { this.cycleArtistLoadLimit(); })
        }
        Text('缓存').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 10 })
        Button('音频缓存上限：' + this.audioCacheGB + ' GB').onClick(() => { this.cycleAudioCacheGB(); })
        Text('音频缓存：' + this.formatBytes(this.audioCacheBytes)).fontSize(12).fontColor(this.coreSub()).width('100%')
        Text('图片缓存：' + this.imageCacheLabel).fontSize(12).fontColor(this.coreSub()).width('100%')
        Text('元数据缓存：' + this.metadataCacheLabel).fontSize(12).fontColor(this.coreSub()).width('100%')
        Row({ space: 6 }) {
          Button('清音频缓存').onClick(() => { this.clearAudioCache(); })
          Button('清图片缓存').onClick(() => { this.clearImageCache(); })
          Button('清元数据缓存').onClick(() => { this.clearMetadataCache(); })
        }
        Column().height(20)
      }.width('100%').padding({ left: 12, right: 12 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreLocalPage() {
    Column() {
      this.coreHeader('本地音乐', () => { this.page = 'main'; })
      Row({ space: 8 }) {
        Button(this.localImportBusy ? '导入中…' : '导入本地音乐').enabled(!this.localImportBusy).onClick(() => { this.importLocalMusic(); })
        Button('重新扫描').onClick(() => { this.scanLocalLibrary(); })
      }.width('100%').padding({ left: 10, right: 10, bottom: 8 })
      Text('已识别 ' + this.localSongs.length + ' 首；下载目录 Meow/download').fontSize(11).fontColor(this.coreSub()).width('100%').padding({ left: 12, bottom: 6 })
      this.coreTrackList(this.localSongs)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreDownloadsPage() {
    Column() {
      this.coreHeader('下载管理', () => { this.page = 'main'; })
      Text('已下载 ' + this.downloadedLocalRows().length + ' 首 · ' + this.formatBytes(this.downloadedTotalBytes()) + ' · 下载中 ' + this.activeDownloadCount())
        .fontSize(12).fontColor(this.coreSub()).width('100%').padding({ left: 12, right: 12, bottom: 8 })
      List() {
        ForEach(this.downloadedLocalRows(), (t: Track, i: number) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(t.title + ' · ' + t.artist).fontSize(14).fontColor(this.coreText()).layoutWeight(1).maxLines(1)
              Button('播放').onClick(() => { this.playList(this.downloadedLocalRows(), i); })
              Button('删除').onClick(() => { this.deleteDownloadedTrack(t); })
            }.width('100%').padding(10)
          }
        }, (t: Track, i: number) => 'dl/' + t.id + '/' + i)
      }.width('100%').layoutWeight(1)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreStatsPage() {
    Scroll() {
      Column({ space: 8 }) {
        this.coreHeader('听歌统计', () => { this.page = 'main'; })
        Text('累计 ' + this.statTimeLabel(this.statTotalSeconds) + ' · 有效播放 ' + this.statTotalPlays + ' · 歌曲 ' + this.statRows.length)
          .fontSize(14).fontColor(this.coreText()).width('100%')
        Text('歌曲排行').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%')
        ForEach(this.topSongStats(), (r: PlayStatRow, i: number) => {
          Text((i + 1) + '. ' + r.title + ' · ' + r.artist + ' · ' + r.plays + ' 次 · ' + this.statTimeLabel(r.seconds))
            .fontSize(13).fontColor(this.coreText()).width('100%').padding({ top: 5, bottom: 5 })
        }, (r: PlayStatRow, i: number) => 'stat/' + i + '/' + r.artist + '/' + r.title)
        Text('歌手排行').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').margin({ top: 8 })
        ForEach(this.topArtistStats(), (r: ArtistStatRow, i: number) => {
          Text((i + 1) + '. ' + r.artist + ' · ' + r.plays + ' 次 · ' + this.statTimeLabel(r.seconds))
            .fontSize(13).fontColor(this.coreText()).width('100%').padding({ top: 5, bottom: 5 })
        }, (r: ArtistStatRow, i: number) => 'astat/' + i + '/' + r.artist)
        Column().height(20)
      }.width('100%').padding({ left: 12, right: 12 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreFollowedPage() {
    Column() {
      this.coreHeader('关注的歌手', () => { this.page = 'main'; })
      this.coreArtistList(this.followedArtistRows())
    }.width('100%').layoutWeight(1)
  }

  @Builder
  coreLikedPage() {
    Column() { this.coreHeader('收藏', () => { this.page = 'main'; }); this.coreTrackList(this.liked) }
      .width('100%').layoutWeight(1)
  }

  @Builder
  coreRecentPage() {
    Column() { this.coreHeader('最近播放', () => { this.page = 'main'; }); this.coreAlbumList(this.recent) }
      .width('100%').layoutWeight(1)
  }

  @Builder
  coreMainShell() {
    Column() {
      Row() {
        Text('Meow Core').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.coreText()).layoutWeight(1)
        Text(this.buildLabel).fontSize(10).fontColor(this.coreSub()).maxLines(1)
      }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 4 })
      this.coreStatus()
      Scroll() {
        Row({ space: 6 }) {
          this.coreNavButton('首页', this.tab === 0, () => { this.coreSelectTab(0); })
          this.coreNavButton('资料库', this.tab === 1, () => { this.coreSelectTab(1); })
          this.coreNavButton('搜索', this.tab === 2, () => { this.coreSelectTab(2); })
          this.coreNavButton('我的', this.tab === 3, () => { this.coreSelectTab(3); })
        }.padding({ left: 10, right: 10, bottom: 8 })
      }.scrollable(ScrollDirection.Horizontal).width('100%')
      if (this.tab === 0) this.coreHomePage()
      else if (this.tab === 1) this.coreLibraryPage()
      else if (this.tab === 2) this.coreSearchPage()
      else this.coreMePage()
      this.coreMiniPlayer()
    }.width('100%').height('100%')
  }

  @Builder
  corePlaylistDialogs() {
    if (this.plDlgMode > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.plDlgMode = 0; })
        Column({ space: 10 }) {
          Text(this.plDlgMode === 1 ? '新建歌单' : '重命名歌单').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.coreText())
          TextInput({ text: this.plDlgName, placeholder: '歌单名称' }).onChange((v: string) => { this.plDlgName = v; })
          Row({ space: 8 }) {
            Button('取消').onClick(() => { this.plDlgMode = 0; })
            Button('确定').onClick(() => { this.confirmPlDlg(); })
          }
        }.width('86%').padding(18).backgroundColor(this.coreCard()).borderRadius(10)
      }.width('100%').height('100%').zIndex(60)
    }
    if (this.manageOpen) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.manageOpen = false; })
        Column({ space: 10 }) {
          Text('管理：' + this.manageName).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.coreText())
          TextInput({ text: this.plDlgName, placeholder: '歌单名称' }).onChange((v: string) => { this.plDlgName = v; })
          Row({ space: 6 }) {
            Button('重命名').onClick(() => { this.plDlgMode = 2; this.confirmPlDlg(); })
            Button('复制分享码').onClick(() => { this.shareManage(); })
            Button('删除').onClick(() => { this.deleteManage(); })
          }
          Button('关闭').onClick(() => { this.manageOpen = false; })
        }.width('90%').padding(18).backgroundColor(this.coreCard()).borderRadius(10)
      }.width('100%').height('100%').zIndex(61)
    }
    if (this.importOpen) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.importOpen = false; })
        Column({ space: 10 }) {
          Text('导入歌单分享码').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.coreText())
          TextInput({ text: this.importCode, placeholder: 'LM1./LM2. 分享码' }).onChange((v: string) => { this.importCode = v; })
          Row({ space: 8 }) {
            Button('取消').onClick(() => { this.importOpen = false; })
            Button('导入').onClick(() => { this.importShare(); })
          }
        }.width('90%').padding(18).backgroundColor(this.coreCard()).borderRadius(10)
      }.width('100%').height('100%').zIndex(62)
    }
    if (this.plPickOn) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.plPickOn = false; })
        Column() {
          Text('加入歌单：' + this.plPickTitle).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.coreText()).width('100%').padding(10)
          Button('新建歌单并加入').width('100%').onClick(() => { this.plDlgMode = 1; this.plDlgName = ''; })
          List() {
            ForEach(this.pickPlaylists(), (p: Playlist) => {
              ListItem() { Button(p.name).width('100%').onClick(() => { this.addPick(p); }) }
            }, (p: Playlist) => 'pick/' + p.source + '/' + p.id)
          }.height(360).width('100%')
          Button('取消').width('100%').onClick(() => { this.plPickOn = false; })
        }.width('90%').padding(12).backgroundColor(this.coreCard()).borderRadius(10)
      }.width('100%').height('100%').zIndex(63)
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.coreQueueVisible) this.coreQueuePage()
        else if (this.corePlayerVisible) this.corePlayerPage()
        else if (this.coreDetailVisible) this.coreDetailPage()
        else if (this.page === 'settings') this.coreSettingsPage()
        else if (this.page === 'advanced') this.coreAdvancedPage()
        else if (this.page === 'local') this.coreLocalPage()
        else if (this.page === 'downloads') this.coreDownloadsPage()
        else if (this.page === 'stats') this.coreStatsPage()
        else if (this.page === 'followed') this.coreFollowedPage()
        else if (this.page === 'liked') this.coreLikedPage()
        else if (this.page === 'recent') this.coreRecentPage()
        else this.coreMainShell()
      }
      .width('100%').height('100%').backgroundColor(this.coreBg())
      this.corePlaylistDialogs()
    }.width('100%').height('100%')
  }
}
