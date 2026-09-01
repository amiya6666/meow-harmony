import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { errText } from '../common/Store';

export interface Album {
  id: string;
  source: string;
  title: string;
  artist: string;
  cover: string;
  year: number;
}

export interface Track {
  id: string;
  source: string;
  title: string;
  artist: string;
  album: string;
  albumId: string;
  artistId: string;
  duration: number;
  liked: boolean;
  cover: string;
  stream: string;
  suffix?: string;
  replayGainDb?: number;
  // 本地歌单缓存中的网盘条目在音源离线时会保留为占位项。
  available?: boolean;
  cached?: boolean;
}

export interface Artist {
  id: string;
  source: string;
  name: string;
  albumCount: number;
  cover: string;
}

export interface Playlist {
  id: string;
  source: string;
  name: string;
  songCount: number;
  cover: string;
  local?: boolean;
  available?: boolean;
  cached?: boolean;
}

export interface HomeData {
  newest: Album[];
  recent: Album[];
}

export interface SearchData {
  songs: Track[];
  albums: Album[];
  artists: Artist[];
}

export interface InternetRadio {
  id: string;
  source: string;
  name: string;
  streamUrl: string;
  homepageUrl: string;
}

export interface LyricLine {
  t: number;
  line: string;
}

export interface SourceRow {
  id: string;
  name: string;
  type: string;
  online: boolean;
  url?: string;
  pass?: string;
  user?: string;
}

export function fmtDur(sec: number): string {
  const n = Math.floor(sec);
  const m = Math.floor(n / 60);
  const s = n % 60;
  return m + ':' + (s < 10 ? '0' : '') + s;
}

function bytesHex(u8: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < u8.length; i++) {
    hex += u8[i].toString(16).padStart(2, '0');
  }
  return hex.toUpperCase();
}

async function md5Hex(input: string): Promise<string> {
  try {
    const md = cryptoFramework.createMd('MD5');
    await md.update({ data: new Uint8Array(buffer.from(input, 'utf-8').buffer) });
    const out = await md.digest();
    const u8 = new Uint8Array(out.data);
    let hex = '';
    for (let i = 0; i < u8.length; i++) {
      hex += u8[i].toString(16).padStart(2, '0');
    }
    return hex;
  } catch (e) {
    throw new Error('Navidrome 认证摘要生成失败：' + errText(e as Object));
  }
}

export interface SourceCfg {
  id: string;
  name: string;
  url: string;
  user: string;
  pass: string;
  // subsonic = Navidrome / Subsonic；webdav = OpenList / AList / 通用 WebDAV
  type?: string;
}

export interface StreamAccess {
  url: string;
  headers: Record<string, string>;
  hasHeaders: boolean;
}

function normUrl(url: string): string {
  let s = (url || '').trim().replace(/\/+$/, '');
  if (s.length > 0 && !s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'http://' + s;
  }
  return s;
}

export class SubApi {
  cfg: SourceCfg;
  private authQuery: string = '';

  constructor(cfg: SourceCfg) {
    this.cfg = cfg;
    this.cfg.url = normUrl(cfg.url);
  }

  async ready(): Promise<void> {
    if (this.authQuery.length > 0) {
      return;
    }
    const salt = Math.random().toString(16).replace(/[^a-f0-9]/g, '').substring(0, 3).padEnd(4, 'a') +
      Date.now().toString(16).slice(-4);
    const token = await md5Hex(this.cfg.pass + salt);
    this.authQuery = 'u=' + encodeURIComponent(this.cfg.user) +
      '&t=' + token + '&s=' + salt + '&v=1.16.1&c=meow';
  }

  async ping(): Promise<string> {
    await this.ready();
    const body = await this.getJson('ping');
    return body['serverVersion'] !== undefined ? '' + body['serverVersion'] : '';
  }

  async startScan(fullScan: boolean = false): Promise<void> {
    await this.getJson('startScan', 'fullScan=' + (fullScan ? 'true' : 'false') + '&f=json');
  }

  async isScanning(): Promise<boolean> {
    const root = await this.getJson('getScanStatus', 'f=json');
    const status = root['scanStatus'] as Record<string, Object>;
    if (status === undefined || status['scanning'] === undefined) {
      return false;
    }
    return status['scanning'] === true || ('' + status['scanning']).toLowerCase() === 'true';
  }

  private async hexAuth(): Promise<string> {
    const enc = bytesHex(new Uint8Array(buffer.from(this.cfg.pass, 'utf-8').buffer));
    return 'u=' + encodeURIComponent(this.cfg.user) +
      '&p=enc:' + enc + '&v=1.16.1&c=meow';
  }

  async getJson(path: string, extra: string = ''): Promise<object> {
    await this.ready();
    if (extra.indexOf('f=json') < 0) {
      extra = extra + (extra.length > 0 ? '&' : '') + 'f=json';
    }
    const h = http.createHttp();
    try {
      const url = this.cfg.url + '/rest/' + path + '?' + this.authQuery +
        (extra.length > 0 ? '&' + extra : '');
      const r = await h.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000,
        usingCache: false
      });
      if (r.responseCode < 200 || r.responseCode >= 300) {
        throw new Error('HTTP ' + r.responseCode);
      }
      const text = '' + r.result;
      let obj: Record<string, object>;
      try {
        obj = JSON.parse(text) as Record<string, object>;
      } catch (_p) {
        const head = text.trim().replace(/\s+/g, ' ').substring(0, 60);
        if (head.startsWith('<subsonic-response')) {
          throw new Error('音乐服务返回了 XML 而不是 JSON，请更新 App 重试');
        }
        if (text.trim().startsWith('<')) {
          throw new Error('这个地址返回的是网页不是音乐接口（返回：' + head + '）');
        }
        throw new Error('服务器返回了无法解析的数据（' + head + '）');
      }
      const root = obj['subsonic-response'] as Record<string, object>;
      if (root === undefined) {
        throw new Error('不是 Subsonic 兼容服务');
      }
      const status = '' + (root['status'] !== undefined ? root['status'] : 'failed');
      if (status !== 'ok') {
        const err = root['error'] as Record<string, Object>;
        const code = err !== undefined && err['code'] !== undefined ? Number(err['code']) : 0;
        const msg = err !== undefined && err['message'] !== undefined ? '' + err['message'] : status;
        if (code === 40 && this.authQuery.indexOf('&p=enc:') < 0) {
          this.authQuery = await this.hexAuth();
          h.destroy();
          return await this.getJson(path, extra);
        }
        throw new Error(msg);
      }
      return root;
    } catch (e) {
      throw new Error(errText(e as Object));
    } finally {
      h.destroy();
    }
  }

  coverUrl(coverId: string): string {
    if (coverId.length === 0) {
      return '';
    }
    return this.cfg.url + '/rest/getCoverArt?' + this.authQuery + '&id=' + encodeURIComponent(coverId);
  }

  streamUrl(songId: string): string {
    return this.cfg.url + '/rest/stream?' + this.authQuery + '&id=' + encodeURIComponent(songId);
  }

  downloadUrl(songId: string, br: number = 0): string {
    let url = this.cfg.url + '/rest/download?' + this.authQuery + '&id=' + encodeURIComponent(songId);
    if (br > 0) {
      url += '&maxBitRate=' + br + '&format=mp3';
    }
    return url;
  }

  mapAlbum(src: string, x: Record<string, Object>): Album {
    const cv = x['coverArt'] !== undefined ? '' + x['coverArt'] : (x['id'] !== undefined ? '' + x['id'] : '');
    return {
      id: '' + (x['id'] !== undefined ? x['id'] : ''),
      source: src,
      title: '' + (x['name'] !== undefined ? x['name'] : (x['title'] !== undefined ? x['title'] : '')),
      artist: '' + (x['artist'] !== undefined ? x['artist'] : ''),
      cover: this.coverUrl(cv),
      year: Number(x['year'] !== undefined ? x['year'] : 0)
    };
  }

  mapTrack(src: string, x: Record<string, Object>, albumTitle: string): Track {
    const cv = x['coverArt'] !== undefined ? '' + x['coverArt'] : (x['albumId'] !== undefined ? '' + x['albumId'] : '');
    const starred = x['starred'] !== undefined;
    const replay = x['replayGain'] as Record<string, Object>;
    const gain = replay !== undefined && replay['trackGain'] !== undefined ? Number(replay['trackGain']) : 0;
    return {
      id: '' + (x['id'] !== undefined ? x['id'] : ''),
      source: src,
      title: '' + (x['title'] !== undefined ? x['title'] : ''),
      artist: '' + (x['artist'] !== undefined ? x['artist'] : ''),
      album: '' + (x['album'] !== undefined ? x['album'] : albumTitle),
      albumId: '' + (x['albumId'] !== undefined ? x['albumId'] : ''),
      artistId: '' + (x['artistId'] !== undefined ? x['artistId'] : ''),
      duration: Number(x['duration'] !== undefined ? x['duration'] : 0),
      liked: starred,
      cover: this.coverUrl(cv),
      stream: this.streamUrl('' + (x['id'] !== undefined ? x['id'] : '')),
      suffix: x['suffix'] !== undefined ? '' + x['suffix'] : '',
      replayGainDb: gain
    };
  }

  mapArtist(src: string, x: Record<string, Object>): Artist {
    const cv = x['coverArt'] !== undefined ? '' + x['coverArt'] : (x['id'] !== undefined ? '' + x['id'] : '');
    return {
      id: '' + (x['id'] !== undefined ? x['id'] : ''),
      source: src,
      name: '' + (x['name'] !== undefined ? x['name'] : ''),
      albumCount: Number(x['albumCount'] !== undefined ? x['albumCount'] : 0),
      cover: this.coverUrl(cv)
    };
  }

  async albumList(kind: string, size: number): Promise<Album[]> {
    const root = await this.getJson('getAlbumList2', 'type=' + kind + '&size=' + size + '&f=json');
    const out: Album[] = [];
    const l2 = root['albumList2'] as Record<string, Object>;
    if (l2 === undefined) {
      return out;
    }
    const rows = l2['album'] as Array<Record<string, Object>>;
    if (rows === undefined) {
      return out;
    }
    for (let i = 0; i < rows.length; i++) {
      out.push(this.mapAlbum(this.cfg.id, rows[i]));
    }
    return out;
  }

  async allSongs(): Promise<Track[]> {
    const root = await this.getJson('search3', 'query=&songCount=500&albumCount=0&artistCount=0&f=json');
    const out: Track[] = [];
    const s3 = root['searchResult3'] as Record<string, Object>;
    if (s3 === undefined) {
      return out;
    }
    const rows = s3['song'] as Array<Record<string, Object>>;
    if (rows === undefined) {
      return out;
    }
    for (let i = 0; i < rows.length; i++) {
      out.push(this.mapTrack(this.cfg.id, rows[i], ''));
    }
    return out;
  }

  async starredSongs(): Promise<Track[]> {
    const root = await this.getJson('getStarred2', 'f=json');
    const out: Track[] = [];
    const st = root['starred2'] as Record<string, Object>;
    if (st === undefined) {
      return out;
    }
    const rows = st['song'] as Array<Record<string, Object>>;
    if (rows === undefined) {
      return out;
    }
    for (let i = 0; i < rows.length; i++) {
      out.push(this.mapTrack(this.cfg.id, rows[i], ''));
    }
    return out;
  }

  async starIds(id: string, star: boolean): Promise<void> {
    await this.getJson(star ? 'star' : 'unstar', 'id=' + encodeURIComponent(id) + '&f=json');
  }

  async search3(q: string): Promise<SearchData> {
    const root = await this.getJson('search3', 'query=' + encodeURIComponent(q) +
      '&songCount=80&albumCount=40&artistCount=20&f=json');
    const data: SearchData = { songs: [], albums: [], artists: [] };
    const s3 = root['searchResult3'] as Record<string, Object>;
    if (s3 === undefined) {
      return data;
    }
    const songs = s3['song'] as Array<Record<string, Object>>;
    if (songs !== undefined) {
      for (let i = 0; i < songs.length; i++) {
        data.songs.push(this.mapTrack(this.cfg.id, songs[i], ''));
      }
    }
    const albums = s3['album'] as Array<Record<string, Object>>;
    if (albums !== undefined) {
      for (let i = 0; i < albums.length; i++) {
        data.albums.push(this.mapAlbum(this.cfg.id, albums[i]));
      }
    }
    const artists = s3['artist'] as Array<Record<string, Object>>;
    if (artists !== undefined) {
      for (let i = 0; i < artists.length; i++) {
        data.artists.push(this.mapArtist(this.cfg.id, artists[i]));
      }
    }
    return data;
  }

  async internetRadios(): Promise<InternetRadio[]> {
    const root = await this.getJson('getInternetRadioStations', 'f=json');
    const out: InternetRadio[] = [];
    const top = root['internetRadioStations'] as Record<string, Object>;
    const rows = top !== undefined ? top['internetRadioStation'] as Array<Record<string, Object>> : undefined;
    if (rows === undefined) return out;
    for (let i = 0; i < rows.length; i++) {
      const x = rows[i];
      const streamUrl = '' + (x['streamUrl'] !== undefined ? x['streamUrl'] : '');
      if (streamUrl.length === 0) continue;
      out.push({
        id: '' + (x['id'] !== undefined ? x['id'] : ('radio-' + i)),
        source: this.cfg.id,
        name: '' + (x['name'] !== undefined ? x['name'] : '网络电台'),
        streamUrl: streamUrl,
        homepageUrl: '' + (x['homepageUrl'] !== undefined ? x['homepageUrl'] : '')
      });
    }
    return out;
  }

  async topSongs(artist: string, count: number = 100): Promise<Track[]> {
    const root = await this.getJson('getTopSongs', 'artist=' + encodeURIComponent(artist) +
      '&count=' + count + '&f=json');
    const out: Track[] = [];
    const top = root['topSongs'] as Record<string, Object>;
    if (top === undefined) {
      return out;
    }
    const rows = top['song'] as Array<Record<string, Object>>;
    if (rows === undefined) {
      return out;
    }
    for (let i = 0; i < rows.length; i++) {
      out.push(this.mapTrack(this.cfg.id, rows[i], ''));
    }
    return out;
  }

  async similarSongs(songId: string, artistId: string, artist: string, count: number = 50): Promise<Track[]> {
    // getSimilarSongs2 expects an artist id in the Subsonic API. Passing the song id
    // works only on some server/plugin combinations, so prefer artistId here.
    const similar2Id = artistId.length > 0 ? artistId : songId;
    try {
      const root = await this.getJson('getSimilarSongs2', 'id=' + encodeURIComponent(similar2Id) +
        '&count=' + count + '&f=json');
      const out: Track[] = [];
      const top = root['similarSongs2'] as Record<string, Object>;
      if (top !== undefined) {
        const rows = top['song'] as Array<Record<string, Object>>;
        if (rows !== undefined) {
          for (let i = 0; i < rows.length; i++) {
            out.push(this.mapTrack(this.cfg.id, rows[i], ''));
          }
        }
      }
      if (out.length > 0) {
        return out;
      }
    } catch (_e) {
    }

    // The older endpoint accepts song/album/artist ids, so try the song first.
    try {
      const root = await this.getJson('getSimilarSongs', 'id=' + encodeURIComponent(songId) +
        '&count=' + count + '&f=json');
      const out: Track[] = [];
      const top = root['similarSongs'] as Record<string, Object>;
      if (top !== undefined) {
        const rows = top['song'] as Array<Record<string, Object>>;
        if (rows !== undefined) {
          for (let i = 0; i < rows.length; i++) {
            out.push(this.mapTrack(this.cfg.id, rows[i], ''));
          }
        }
      }
      if (out.length > 0) {
        return out;
      }
    } catch (_e) {
    }

    // If Navidrome has no Last.fm/AudioMuse similarity provider configured, keep
    // the button useful by building a same-artist fallback from normal search.
    if (artist.trim().length > 0) {
      try {
        const data = await this.search3(artist);
        const out: Track[] = [];
        const key = artist.trim().toLowerCase();
        for (let i = 0; i < data.songs.length && out.length < count; i++) {
          const row = data.songs[i];
          if (row.id !== songId && row.artist.trim().toLowerCase() === key) {
            out.push(row);
          }
        }
        return out;
      } catch (_e) {
      }
    }
    return [];
  }

  async scrobble(songId: string, submission: boolean): Promise<void> {
    await this.getJson('scrobble', 'id=' + encodeURIComponent(songId) +
      '&submission=' + (submission ? 'true' : 'false') + '&time=' + Date.now() + '&f=json');
  }
}

interface DavEntry {
  url: string;
  path: string;
  name: string;
  isDir: boolean;
  modified: number;
  size: number;
}

interface DavTrackMeta {
  track: Track;
  modified: number;
}

function xmlUnescape(s: string): string {
  return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'");
}

function fileExt(name: string): string {
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.substring(i + 1).toLowerCase() : '';
}

function withoutExt(name: string): string {
  const i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

function decodeSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch (_e) {
    return s;
  }
}

function stripTrackNo(s: string): string {
  // 01 - Song / 01. Song / 01 Song -> Song
  return s.replace(/^\s*\d{1,3}\s*[-_. ]\s*/, '').trim();
}

function originOf(url: string): string {
  const mark = url.indexOf('://');
  if (mark < 0) {
    return '';
  }
  const slash = url.indexOf('/', mark + 3);
  return slash >= 0 ? url.substring(0, slash) : url;
}

function pathOf(url: string): string {
  const mark = url.indexOf('://');
  if (mark < 0) {
    return url;
  }
  const slash = url.indexOf('/', mark + 3);
  return slash >= 0 ? url.substring(slash) : '/';
}

function trimSlash(s: string): string {
  let out = s;
  while (out.length > 1 && out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

export class WebDavApi {
  cfg: SourceCfg;
  private auth: string = '';
  private indexed: boolean = false;
  private trackMeta: DavTrackMeta[] = [];
  private albumRows: Album[] = [];
  private albumTimes: number[] = [];
  private artistRows: Artist[] = [];
  private maxTracks: number = 5000;

  constructor(cfg: SourceCfg) {
    this.cfg = cfg;
    this.cfg.url = normUrl(cfg.url);
    if (this.cfg.user.length > 0 || this.cfg.pass.length > 0) {
      const b64 = buffer.from(this.cfg.user + ':' + this.cfg.pass, 'utf-8').toString('base64');
      this.auth = 'Basic ' + b64;
    }
  }

  private headers(depth: string = ''): Record<string, string> {
    const out: Record<string, string> = {};
    if (this.auth.length > 0) {
      out['Authorization'] = this.auth;
    }
    if (depth.length > 0) {
      out['Depth'] = depth;
    }
    out['User-Agent'] = 'Meow/1.5';
    return out;
  }

  streamHeaders(): Record<string, string> {
    return this.headers();
  }

  private async textRequest(url: string, customMethod: string, depth: string = ''): Promise<string> {
    const h = http.createHttp();
    try {
      const r = await h.request(url, {
        method: http.RequestMethod.GET,
        customMethod: customMethod,
        header: this.headers(depth),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: false
      });
      if (r.responseCode < 200 || r.responseCode >= 300) {
        throw new Error('HTTP ' + r.responseCode);
      }
      return '' + r.result;
    } catch (e) {
      throw new Error(errText(e as Object));
    } finally {
      h.destroy();
    }
  }

  private async getOptional(url: string): Promise<string> {
    const h = http.createHttp();
    try {
      const r = await h.request(url, {
        method: http.RequestMethod.GET,
        header: this.headers(),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 12000,
        usingCache: false
      });
      if (r.responseCode === 404) {
        return '';
      }
      if (r.responseCode < 200 || r.responseCode >= 300) {
        return '';
      }
      return '' + r.result;
    } catch (_e) {
      return '';
    } finally {
      h.destroy();
    }
  }

  async ping(): Promise<string> {
    await this.textRequest(this.cfg.url, 'PROPFIND', '0');
    return 'WebDAV';
  }

  invalidate(): void {
    this.indexed = false;
    this.trackMeta = [];
    this.albumRows = [];
    this.albumTimes = [];
    this.artistRows = [];
  }

  private hrefToUrl(href0: string): string {
    let href = xmlUnescape(href0.trim());
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return trimSlash(href);
    }
    if (!href.startsWith('/')) {
      href = '/' + href;
    }
    return trimSlash(originOf(this.cfg.url) + href);
  }

  private hrefPath(href0: string): string {
    const u = this.hrefToUrl(href0);
    return decodeSafe(pathOf(u));
  }

  private tag(block: string, name: string): string {
    const re = new RegExp('<(?:[^:>]+:)?' + name + '[^>]*>([\\s\\S]*?)<\\/(?:[^:>]+:)?' + name + '>', 'i');
    const m = re.exec(block);
    return m !== null ? xmlUnescape(m[1].replace(/<[^>]+>/g, '').trim()) : '';
  }

  private parseDav(xml: string): DavEntry[] {
    const out: DavEntry[] = [];
    const re = /<(?:[^:>]+:)?response\b[\s\S]*?<\/(?:[^:>]+:)?response>/gi;
    const rows = xml.match(re);
    if (rows === null) {
      return out;
    }
    for (let i = 0; i < rows.length; i++) {
      const block = rows[i];
      const href = this.tag(block, 'href');
      if (href.length === 0) {
        continue;
      }
      const path = this.hrefPath(href);
      const seg = path.split('/');
      let name = '';
      for (let k = seg.length - 1; k >= 0; k--) {
        if (seg[k].length > 0) {
          name = seg[k];
          break;
        }
      }
      const isDir = /<(?:[^:>]+:)?collection\b/i.test(block);
      const modifiedText = this.tag(block, 'getlastmodified');
      const sizeText = this.tag(block, 'getcontentlength');
      const modified = modifiedText.length > 0 ? Date.parse(modifiedText) : 0;
      out.push({
        url: this.hrefToUrl(href),
        path: path,
        name: decodeSafe(name),
        isDir: isDir,
        modified: isNaN(modified) ? 0 : modified,
        size: sizeText.length > 0 ? Number(sizeText) : 0
      });
    }
    return out;
  }

  private async listDir(url: string): Promise<DavEntry[]> {
    const xml = await this.textRequest(url, 'PROPFIND', '1');
    const all = this.parseDav(xml);
    const out: DavEntry[] = [];
    const self = trimSlash(url);
    for (let i = 0; i < all.length; i++) {
      if (trimSlash(all[i].url) !== self) {
        out.push(all[i]);
      }
    }
    return out;
  }

  private isAudio(name: string): boolean {
    const ext = fileExt(name);
    return ext === 'mp3' || ext === 'flac' || ext === 'm4a' || ext === 'aac' || ext === 'ogg' ||
      ext === 'opus' || ext === 'wav' || ext === 'ape' || ext === 'alac';
  }

  private relativePath(fullPath: string): string {
    const root = trimSlash(decodeSafe(pathOf(this.cfg.url)));
    let p = decodeSafe(fullPath);
    if (p.startsWith(root)) {
      p = p.substring(root.length);
    }
    if (!p.startsWith('/')) {
      p = '/' + p;
    }
    return p;
  }

  private trackFromEntry(e: DavEntry): Track {
    const rel = this.relativePath(e.path);
    const parts0 = rel.split('/');
    const parts: string[] = [];
    for (let i = 0; i < parts0.length; i++) {
      if (parts0[i].trim().length > 0) {
        parts.push(parts0[i].trim());
      }
    }
    const file = parts.length > 0 ? parts[parts.length - 1] : e.name;
    const album = parts.length >= 2 ? parts[parts.length - 2] : '网盘音乐';
    let artist = parts.length >= 3 ? parts[parts.length - 3] : '网盘';
    let title = stripTrackNo(withoutExt(file));
    const dash = title.indexOf(' - ');
    if ((artist === '网盘' || artist === 'Music' || artist === '音乐') && dash > 0) {
      artist = title.substring(0, dash).trim();
      title = title.substring(dash + 3).trim();
    }
    const albumPath = parts.length >= 2 ? '/' + parts.slice(0, parts.length - 1).join('/') : '/';
    const artistPath = parts.length >= 3 ? '/' + parts.slice(0, parts.length - 2).join('/') : '/@webdav';
    return {
      id: rel,
      source: this.cfg.id,
      title: title.length > 0 ? title : file,
      artist: artist,
      album: album,
      albumId: albumPath,
      artistId: artistPath,
      duration: 0,
      liked: false,
      cover: '',
      stream: e.url,
      suffix: fileExt(file)
    };
  }

  private rebuildGroups(): void {
    this.albumRows = [];
    this.albumTimes = [];
    const artistIds: string[] = [];
    const artistNames: string[] = [];
    const artistAlbumIds: string[][] = [];
    for (let i = 0; i < this.trackMeta.length; i++) {
      const t = this.trackMeta[i].track;
      let ai = -1;
      for (let j = 0; j < this.albumRows.length; j++) {
        if (this.albumRows[j].id === t.albumId) {
          ai = j;
          break;
        }
      }
      if (ai < 0) {
        this.albumRows.push({
          id: t.albumId, source: this.cfg.id, title: t.album, artist: t.artist, cover: '', year: 0
        });
        this.albumTimes.push(this.trackMeta[i].modified);
      } else if (this.trackMeta[i].modified > this.albumTimes[ai]) {
        this.albumTimes[ai] = this.trackMeta[i].modified;
      }

      let ar = artistIds.indexOf(t.artistId);
      if (ar < 0) {
        artistIds.push(t.artistId);
        artistNames.push(t.artist);
        artistAlbumIds.push([]);
        ar = artistIds.length - 1;
      }
      if (artistAlbumIds[ar].indexOf(t.albumId) < 0) {
        artistAlbumIds[ar].push(t.albumId);
      }
    }
    // newest first for cloud folders
    const order: number[] = [];
    for (let i = 0; i < this.albumRows.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number) => this.albumTimes[b] - this.albumTimes[a]);
    const sortedAlbums: Album[] = [];
    const sortedTimes: number[] = [];
    for (let i = 0; i < order.length; i++) {
      sortedAlbums.push(this.albumRows[order[i]]);
      sortedTimes.push(this.albumTimes[order[i]]);
    }
    this.albumRows = sortedAlbums;
    this.albumTimes = sortedTimes;

    this.artistRows = [];
    for (let i = 0; i < artistIds.length; i++) {
      this.artistRows.push({
        id: artistIds[i], source: this.cfg.id, name: artistNames[i],
        albumCount: artistAlbumIds[i].length, cover: ''
      });
    }
  }

  private async ensureIndex(): Promise<void> {
    if (this.indexed) {
      return;
    }
    const queue: string[] = [trimSlash(this.cfg.url)];
    const seen: string[] = [];
    const meta: DavTrackMeta[] = [];
    let depthGuard = 0;
    while (queue.length > 0 && meta.length < this.maxTracks && depthGuard < 6000) {
      const dir = queue.shift();
      if (dir === undefined) {
        break;
      }
      const key = trimSlash(dir);
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      depthGuard++;
      let rows: DavEntry[] = [];
      try {
        rows = await this.listDir(dir);
      } catch (_e) {
        continue;
      }
      for (let i = 0; i < rows.length && meta.length < this.maxTracks; i++) {
        const r = rows[i];
        if (r.name.startsWith('.')) {
          continue;
        }
        if (r.isDir) {
          queue.push(r.url);
        } else if (this.isAudio(r.name)) {
          meta.push({ track: this.trackFromEntry(r), modified: r.modified });
        }
      }
    }
    this.trackMeta = meta;
    this.rebuildGroups();
    this.indexed = true;
  }

  async songs(): Promise<Track[]> {
    await this.ensureIndex();
    const out: Track[] = [];
    for (let i = 0; i < this.trackMeta.length; i++) {
      out.push(this.trackMeta[i].track);
    }
    return out;
  }

  async albums(): Promise<Album[]> {
    await this.ensureIndex();
    return this.albumRows.slice();
  }

  async artists(): Promise<Artist[]> {
    await this.ensureIndex();
    return this.artistRows.slice();
  }

  async home(): Promise<HomeData> {
    await this.ensureIndex();
    const newest: Album[] = [];
    const recent: Album[] = [];
    for (let i = 0; i < this.albumRows.length && i < 16; i++) {
      newest.push(this.albumRows[i]);
    }
    for (let i = 0; i < this.albumRows.length && i < 24; i++) {
      recent.push(this.albumRows[i]);
    }
    return { newest: newest, recent: recent };
  }

  async album(id: string): Promise<AlbumPayload> {
    await this.ensureIndex();
    let head: Album | undefined = undefined;
    for (let i = 0; i < this.albumRows.length; i++) {
      if (this.albumRows[i].id === id) {
        head = this.albumRows[i];
        break;
      }
    }
    if (head === undefined) {
      throw new Error('网盘专辑不存在');
    }
    const tracks: Track[] = [];
    for (let i = 0; i < this.trackMeta.length; i++) {
      if (this.trackMeta[i].track.albumId === id) {
        tracks.push(this.trackMeta[i].track);
      }
    }
    return { title: head.title, artist: head.artist, cover: head.cover, tracks: tracks };
  }

  async artist(id: string): Promise<ArtistPayload> {
    await this.ensureIndex();
    let head: Artist | undefined = undefined;
    for (let i = 0; i < this.artistRows.length; i++) {
      if (this.artistRows[i].id === id) {
        head = this.artistRows[i];
        break;
      }
    }
    if (head === undefined) {
      throw new Error('网盘歌手不存在');
    }
    const albums: Album[] = [];
    for (let i = 0; i < this.trackMeta.length; i++) {
      const t = this.trackMeta[i].track;
      if (t.artistId === id) {
        let exists = false;
        for (let j = 0; j < albums.length; j++) {
          if (albums[j].id === t.albumId) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          albums.push({ id: t.albumId, source: this.cfg.id, title: t.album, artist: t.artist, cover: '', year: 0 });
        }
      }
    }
    return { name: head.name, cover: '', albums: albums };
  }

  async search(q: string): Promise<SearchData> {
    await this.ensureIndex();
    const key = q.trim().toLowerCase();
    const out: SearchData = { songs: [], albums: [], artists: [] };
    if (key.length === 0) {
      return out;
    }
    for (let i = 0; i < this.trackMeta.length && out.songs.length < 100; i++) {
      const t = this.trackMeta[i].track;
      if ((t.title + ' ' + t.artist + ' ' + t.album).toLowerCase().indexOf(key) >= 0) {
        out.songs.push(t);
      }
    }
    for (let i = 0; i < this.albumRows.length && out.albums.length < 50; i++) {
      const a = this.albumRows[i];
      if ((a.title + ' ' + a.artist).toLowerCase().indexOf(key) >= 0) {
        out.albums.push(a);
      }
    }
    for (let i = 0; i < this.artistRows.length && out.artists.length < 50; i++) {
      if (this.artistRows[i].name.toLowerCase().indexOf(key) >= 0) {
        out.artists.push(this.artistRows[i]);
      }
    }
    return out;
  }

  async lyrics(t: Track): Promise<LyricLine[]> {
    const dot = t.stream.lastIndexOf('.');
    if (dot < 0) {
      return [];
    }
    const url = t.stream.substring(0, dot) + '.lrc';
    const text = await this.getOptional(url);
    if (text.length === 0) {
      return [];
    }
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
        if (line.length > 0) {
          out.push({ t: sec, line: line });
        }
        m = re.exec(raw);
      }
      re.lastIndex = 0;
    }
    out.sort((a: LyricLine, b: LyricLine) => a.t - b.t);
    return out;
  }
}

export interface AlbumPayload {
  title: string;
  artist: string;
  cover: string;
  tracks: Track[];
}

export interface ArtistPayload {
  name: string;
  cover: string;
  albums: Album[];
}

export interface PlaylistPayload {
  name: string;
  cover: string;
  tracks: Track[];
}

const SOURCES_KEY = 'nsSources';

export class MusicSourceManager {
  private cfgs: SourceCfg[] = [];
  private subApis: SubApi[] = [];
  private davApis: WebDavApi[] = [];
  // 0=仅 NAS/Navidrome, 1=仅网盘, 2=合并
  private sourceMode: number = 2;
  private songLimit: number = 500;
  private albumLimit: number = 200;
  private artistLimit: number = 200;

  setLoadLimits(songLimit: number, albumLimit: number, artistLimit: number): void {
    this.songLimit = songLimit > 0 ? songLimit : 500;
    this.albumLimit = albumLimit > 0 ? albumLimit : 200;
    this.artistLimit = artistLimit > 0 ? artistLimit : 200;
  }

  setSourceMode(mode: number): void {
    this.sourceMode = mode >= 0 && mode <= 2 ? mode : 2;
  }

  getSourceMode(): number {
    return this.sourceMode;
  }

  setSources(cfgs: SourceCfg[]): void {
    this.cfgs = cfgs;
    this.subApis = [];
    this.davApis = [];
    for (let i = 0; i < cfgs.length; i++) {
      const kind = cfgs[i].type === 'webdav' ? 'webdav' : 'subsonic';
      cfgs[i].type = kind;
      if (kind === 'webdav') {
        this.davApis.push(new WebDavApi(cfgs[i]));
      } else {
        this.subApis.push(new SubApi(cfgs[i]));
      }
    }
  }

  getSources(): SourceCfg[] {
    return this.cfgs;
  }

  static async loadSourceCfgs(ctx: common.UIAbilityContext): Promise<SourceCfg[]> {
    try {
      const p = await preferences.getPreferences(ctx, 'lumen');
      const raw = '' + (await p.get(SOURCES_KEY, '[]'));
      const arr = JSON.parse(raw) as SourceCfg[];
      if (arr === undefined || arr === null) {
        return [];
      }
      for (let i = 0; i < arr.length; i++) {
        if (arr[i].type !== 'webdav') {
          arr[i].type = 'subsonic';
        }
      }
      return arr;
    } catch (_e) {
      return [];
    }
  }

  static async saveSourceCfgs(ctx: common.UIAbilityContext, cfgs: SourceCfg[]): Promise<void> {
    try {
      const p = await preferences.getPreferences(ctx, 'lumen');
      await p.put(SOURCES_KEY, JSON.stringify(cfgs));
      await p.flush();
    } catch (e) {
      throw new Error('保存音乐源配置失败：' + errText(e as Object));
    }
  }

  private activeSub(): SubApi[] {
    return this.sourceMode === 1 ? [] : this.subApis;
  }

  private activeDav(): WebDavApi[] {
    return this.sourceMode === 0 ? [] : this.davApis;
  }

  private api(source: string): SubApi {
    for (let i = 0; i < this.subApis.length; i++) {
      if (this.subApis[i].cfg.id === source) {
        return this.subApis[i];
      }
    }
    throw new Error('这个功能只支持 NAS（Navidrome）音乐源');
  }

  private dav(source: string): WebDavApi {
    for (let i = 0; i < this.davApis.length; i++) {
      if (this.davApis[i].cfg.id === source) {
        return this.davApis[i];
      }
    }
    throw new Error('网盘音乐源不存在');
  }

  sourceType(source: string): string {
    if (source === 'local') {
      return 'local';
    }
    // cache-webdav 是觅乐本地歌单缓存使用的虚拟网盘来源。
    if (source === 'cache-webdav') {
      return 'webdav';
    }
    for (let i = 0; i < this.cfgs.length; i++) {
      if (this.cfgs[i].id === source) {
        return this.cfgs[i].type === 'webdav' ? 'webdav' : 'subsonic';
      }
    }
    return 'subsonic';
  }

  invalidateCloud(): void {
    for (let i = 0; i < this.davApis.length; i++) {
      this.davApis[i].invalidate();
    }
  }

  async home(): Promise<HomeData> {
    const newest: Album[] = [];
    const recent: Album[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      const api = subs[i];
      jobs.push(api.albumList('newest', 12).then((rows: Album[]) => {
        for (let j = 0; j < rows.length; j++) newest.push(rows[j]);
      }).catch(() => {}));
      jobs.push(api.albumList('recent', 24).then((rows: Album[]) => {
        for (let j = 0; j < rows.length; j++) recent.push(rows[j]);
      }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].home().then((h: HomeData) => {
        for (let j = 0; j < h.newest.length; j++) newest.push(h.newest[j]);
        for (let j = 0; j < h.recent.length; j++) recent.push(h.recent[j]);
      }).catch(() => {}));
    }
    await Promise.all(jobs);
    return { newest: newest, recent: recent };
  }

  async recentAlbums(): Promise<Album[]> {
    const out: Album[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].albumList('recent', 80).then((rows: Album[]) => {
        for (let j = 0; j < rows.length; j++) out.push(rows[j]);
      }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].albums().then((rows: Album[]) => {
        for (let j = 0; j < rows.length && j < 80; j++) out.push(rows[j]);
      }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out;
  }

  async songs(): Promise<Track[]> {
    const out: Track[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].allSongs().then((rows: Track[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].songs().then((rows: Track[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out.length > this.songLimit ? out.slice(0, this.songLimit) : out;
  }

  async albums(): Promise<Album[]> {
    const out: Album[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].albumList('alphabeticalByName', 500).then((rows: Album[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].albums().then((rows: Album[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out.length > this.albumLimit ? out.slice(0, this.albumLimit) : out;
  }

  async artists(): Promise<Artist[]> {
    const out: Artist[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      const api = subs[i];
      jobs.push(api.getJson('getArtists', 'f=json').then((root: object) => {
        const r = root as Record<string, Object>;
        const top = r['artists'] as Record<string, Object>;
        const groups = top !== undefined ? top['index'] as Array<Record<string, Object>> : undefined;
        if (groups === undefined) return;
        for (let g = 0; g < groups.length; g++) {
          const rows = groups[g]['artist'] as Array<Record<string, Object>>;
          if (rows === undefined) continue;
          for (let j = 0; j < rows.length; j++) out.push(api.mapArtist(api.cfg.id, rows[j]));
        }
      }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].artists().then((rows: Artist[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out.length > this.artistLimit ? out.slice(0, this.artistLimit) : out;
  }

  async playlists(): Promise<Playlist[]> {
    const out: Playlist[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    for (let i = 0; i < subs.length; i++) {
      const api = subs[i];
      jobs.push(api.getJson('getPlaylists', 'f=json').then((root: object) => {
        const r = root as Record<string, Object>;
        const top = r['playlists'] as Record<string, Object>;
        const rows = top !== undefined ? top['playlist'] as Array<Record<string, Object>> : undefined;
        if (rows === undefined) return;
        for (let j = 0; j < rows.length; j++) {
          const x = rows[j];
          const cv = x['coverArt'] !== undefined ? '' + x['coverArt'] : '';
          out.push({ id: '' + (x['id'] !== undefined ? x['id'] : ''), source: api.cfg.id,
            name: '' + (x['name'] !== undefined ? x['name'] : ''),
            songCount: Number(x['songCount'] !== undefined ? x['songCount'] : 0), cover: api.coverUrl(cv) });
        }
      }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out;
  }

  async liked(): Promise<Track[]> {
    const out: Track[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].starredSongs().then((rows: Track[]) => { for (let j = 0; j < rows.length; j++) out.push(rows[j]); }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out;
  }

  async album(source: string, id: string): Promise<AlbumPayload> {
    if (this.sourceType(source) === 'webdav') {
      return await this.dav(source).album(id);
    }
    const api = this.api(source);
    const root = await api.getJson('getAlbum', 'id=' + encodeURIComponent(id) + '&f=json');
    const top = root['album'] as Record<string, Object>;
    if (top === undefined) throw new Error('专辑不存在');
    const head = api.mapAlbum(source, top);
    const tracks: Track[] = [];
    const rows = top['song'] as Array<Record<string, Object>>;
    if (rows !== undefined) for (let i = 0; i < rows.length; i++) tracks.push(api.mapTrack(source, rows[i], head.title));
    return { title: head.title, artist: head.artist, cover: head.cover, tracks: tracks };
  }

  async artist(source: string, id: string): Promise<ArtistPayload> {
    if (this.sourceType(source) === 'webdav') {
      return await this.dav(source).artist(id);
    }
    const api = this.api(source);
    const root = await api.getJson('getArtist', 'id=' + encodeURIComponent(id) + '&f=json');
    const top = root['artist'] as Record<string, Object>;
    if (top === undefined) throw new Error('艺人不存在');
    const head = api.mapArtist(source, top);
    const albums: Album[] = [];
    const rows = top['album'] as Array<Record<string, Object>>;
    if (rows !== undefined) for (let i = 0; i < rows.length; i++) albums.push(api.mapAlbum(source, rows[i]));
    return { name: head.name, cover: head.cover, albums: albums };
  }

  async playlist(source: string, id: string): Promise<PlaylistPayload> {
    const api = this.api(source);
    const root = await api.getJson('getPlaylist', 'id=' + encodeURIComponent(id) + '&f=json');
    const top = root['playlist'] as Record<string, Object>;
    if (top === undefined) throw new Error('歌单不存在');
    const tracks: Track[] = [];
    const rows = top['entry'] as Array<Record<string, Object>>;
    if (rows !== undefined) for (let i = 0; i < rows.length; i++) tracks.push(api.mapTrack(source, rows[i], ''));
    return { name: '' + (top['name'] !== undefined ? top['name'] : '歌单'), cover: tracks.length > 0 ? tracks[0].cover : '', tracks: tracks };
  }

  async search(q: string): Promise<SearchData> {
    const out: SearchData = { songs: [], albums: [], artists: [] };
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    const davs = this.activeDav();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].search3(q).then((d: SearchData) => {
        for (let j = 0; j < d.songs.length; j++) out.songs.push(d.songs[j]);
        for (let j = 0; j < d.albums.length; j++) out.albums.push(d.albums[j]);
        for (let j = 0; j < d.artists.length; j++) out.artists.push(d.artists[j]);
      }).catch(() => {}));
    }
    for (let i = 0; i < davs.length; i++) {
      jobs.push(davs[i].search(q).then((d: SearchData) => {
        for (let j = 0; j < d.songs.length; j++) out.songs.push(d.songs[j]);
        for (let j = 0; j < d.albums.length; j++) out.albums.push(d.albums[j]);
        for (let j = 0; j < d.artists.length; j++) out.artists.push(d.artists[j]);
      }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out;
  }

  async radios(): Promise<InternetRadio[]> {
    const out: InternetRadio[] = [];
    const jobs: Promise<void>[] = [];
    const subs = this.activeSub();
    for (let i = 0; i < subs.length; i++) {
      jobs.push(subs[i].internetRadios().then((rows: InternetRadio[]) => {
        for (let j = 0; j < rows.length; j++) out.push(rows[j]);
      }).catch(() => {}));
    }
    await Promise.all(jobs);
    return out;
  }

  async lyrics(source: string, id: string): Promise<LyricLine[]> {
    if (this.sourceType(source) === 'webdav') {
      const rows = await this.dav(source).songs();
      for (let i = 0; i < rows.length; i++) if (rows[i].id === id) return await this.dav(source).lyrics(rows[i]);
      return [];
    }
    const api = this.api(source);
    const root = await api.getJson('getLyricsBySongId', 'id=' + encodeURIComponent(id) + '&f=json');
    const top = root['lyricsList'] as Record<string, Object>;
    const rows = top !== undefined ? top['structuredLyrics'] as Array<Record<string, Object>> : undefined;
    if (rows !== undefined && rows.length > 0) {
      const lines = rows[0]['line'] as Array<Record<string, Object>>;
      const out: LyricLine[] = [];
      if (lines !== undefined) for (let i = 0; i < lines.length; i++) out.push({ t: Number(lines[i]['start'] !== undefined ? lines[i]['start'] : 0) / 1000, line: '' + (lines[i]['value'] !== undefined ? lines[i]['value'] : '') });
      if (out.length > 0) return out;
    }
    throw new Error('没有歌词');
  }

  async songLyrics(source: string, t: Track): Promise<LyricLine[]> {
    if (this.sourceType(source) === 'webdav') {
      return await this.dav(source).lyrics(t);
    }
    const api = this.api(source);
    try {
      return await this.lyrics(source, t.id);
    } catch (_e) {
    }
    try {
      const root = await api.getJson('getLyrics', 'artist=' + encodeURIComponent(t.artist) + '&title=' + encodeURIComponent(t.title) + '&f=json');
      const top = root['lyrics'] as Record<string, Object>;
      const text = top !== undefined ? '' + (top['value'] !== undefined ? top['value'] : '') : '';
      const raw = text.split('\n');
      const out: LyricLine[] = [];
      for (let i = 0; i < raw.length; i++) if (raw[i].trim().length > 0) out.push({ t: i * 3.2, line: raw[i].trim() });
      return out;
    } catch (_e) {
      return [];
    }
  }

  async artistTopSongs(source: string, artist: string, count: number = 100): Promise<Track[]> {
    if (this.sourceType(source) === 'webdav') {
      const rows = await this.dav(source).songs();
      const out: Track[] = [];
      const key = artist.trim().toLowerCase();
      for (let i = 0; i < rows.length && out.length < count; i++) if (rows[i].artist.trim().toLowerCase() === key) out.push(rows[i]);
      return out;
    }
    return await this.api(source).topSongs(artist, count);
  }

  async similarSongs(t: Track, count: number = 50): Promise<Track[]> {
    if (this.sourceType(t.source) === 'webdav') {
      const rows = await this.dav(t.source).songs();
      const out: Track[] = [];
      for (let i = 0; i < rows.length && out.length < count; i++) {
        if (rows[i].id !== t.id && (rows[i].artist === t.artist || rows[i].album === t.album)) out.push(rows[i]);
      }
      return out;
    }
    return await this.api(t.source).similarSongs(t.id, t.artistId, t.artist, count);
  }

  async scrobble(t: Track, submission: boolean): Promise<void> {
    if (this.sourceType(t.source) === 'webdav' || this.sourceType(t.source) === 'local' || t.suffix === 'radio') return;
    await this.api(t.source).scrobble(t.id, submission);
  }

  async detectSongSource(songId: string): Promise<string> {
    for (let i = 0; i < this.subApis.length; i++) {
      try {
        const root = await this.subApis[i].getJson('getSong', 'id=' + encodeURIComponent(songId) + '&f=json');
        const song = root['song'] as Record<string, Object>;
        if (song !== undefined && song['id'] !== undefined) return this.subApis[i].cfg.id;
      } catch (_e) {}
    }
    for (let i = 0; i < this.davApis.length; i++) {
      const rows = await this.davApis[i].songs();
      for (let j = 0; j < rows.length; j++) if (rows[j].id === songId) return this.davApis[i].cfg.id;
    }
    throw new Error('没有音乐源能识别分享码中的歌曲');
  }

  async star(t: Track, starred: boolean): Promise<void> {
    if (this.sourceType(t.source) === 'webdav') {
      throw new Error('网盘曲目暂不支持同步收藏');
    }
    if (this.sourceType(t.source) === 'local' || t.suffix === 'radio') {
      throw new Error('本地音乐与电台不写入 Navidrome 收藏');
    }
    await this.api(t.source).starIds(t.id, starred);
  }

  async createPlaylist(source: string, name: string, songIds: string[]): Promise<string> {
    if (this.sourceType(source) === 'webdav') throw new Error('网盘曲目暂不支持服务器歌单');
    let extra = 'name=' + encodeURIComponent(name);
    for (let i = 0; i < songIds.length; i++) extra += '&songId=' + encodeURIComponent(songIds[i]);
    const root = await this.api(source).getJson('createPlaylist', extra);
    const top = root['playlist'] as Record<string, Object>;
    return top !== undefined && top['id'] !== undefined ? '' + top['id'] : '';
  }

  async renamePlaylist(source: string, id: string, name: string): Promise<void> {
    await this.api(source).getJson('updatePlaylist', 'playlistId=' + encodeURIComponent(id) + '&name=' + encodeURIComponent(name) + '&f=json');
  }

  async deletePlaylist(source: string, id: string): Promise<void> {
    await this.api(source).getJson('deletePlaylist', 'id=' + encodeURIComponent(id) + '&f=json');
  }

  async addToPlaylist(source: string, plId: string, t: Track): Promise<void> {
    if (this.sourceType(t.source) === 'webdav' || t.source !== source) throw new Error('网盘歌曲或不同音乐源不能直接加入 NAS 服务器歌单');
    await this.api(source).getJson('updatePlaylist', 'playlistId=' + encodeURIComponent(plId) + '&songIdToAdd=' + encodeURIComponent(t.id) + '&f=json');
  }

  async sources(): Promise<SourceRow[]> {
    const jobs: Promise<SourceRow>[] = [];
    for (let i = 0; i < this.subApis.length; i++) {
      const api = this.subApis[i];
      const cfg = api.cfg;
      jobs.push(api.ping().then(() => ({ id: cfg.id, name: cfg.name, type: 'subsonic', online: true, url: cfg.url } as SourceRow))
        .catch(() => ({ id: cfg.id, name: cfg.name, type: 'subsonic', online: false, url: cfg.url } as SourceRow)));
    }
    for (let i = 0; i < this.davApis.length; i++) {
      const api = this.davApis[i];
      const cfg = api.cfg;
      jobs.push(api.ping().then(() => ({ id: cfg.id, name: cfg.name, type: 'webdav', online: true, url: cfg.url } as SourceRow))
        .catch(() => ({ id: cfg.id, name: cfg.name, type: 'webdav', online: false, url: cfg.url } as SourceRow)));
    }
    return await Promise.all(jobs);
  }

  streamAccess(t: Track, br: number): StreamAccess {
    if (this.sourceType(t.source) === 'local' || t.suffix === 'radio') {
      return { url: t.stream, headers: {}, hasHeaders: false };
    }
    if (this.sourceType(t.source) === 'webdav') {
      const h = this.dav(t.source).streamHeaders();
      return { url: t.stream, headers: h, hasHeaders: h['Authorization'] !== undefined };
    }
    let url = t.stream;
    if (br > 0 && url.indexOf('maxBitRate') < 0) {
      // Let the Subsonic/Navidrome server choose its configured downsampling format instead of
      // forcing MP3. estimateContentLength improves compatibility with AVPlayer for transcoded streams.
      url += '&maxBitRate=' + br + '&estimateContentLength=true';
    }
    return { url: url, headers: {}, hasHeaders: false };
  }

  stream(t: Track, br: number): string {
    return this.streamAccess(t, br).url;
  }

  download(t: Track, br: number = 0): string {
    if (this.sourceType(t.source) === 'webdav') return t.stream;
    return this.api(t.source).downloadUrl(t.id, br);
  }

  abs(path: string): string {
    if (path.length === 0) {
      return '';
    }
    if (path.startsWith('http://') || path.startsWith('https://') || path.startsWith('file://')) {
      return path;
    }
    if (path.startsWith('/')) {
      for (let i = 0; i < this.cfgs.length; i++) {
        if (this.cfgs[i].type !== 'webdav') {
          return this.cfgs[i].url + path;
        }
      }
    }
    return path;
  }
}
