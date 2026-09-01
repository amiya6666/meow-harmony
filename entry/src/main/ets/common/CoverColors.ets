import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';

export interface Mood {
  glow: string;
  soft: string;
  deep: string;
}

const FALLBACK: Mood = {
  glow: '#8A8A8E',
  soft: '#2C2C2E',
  deep: '#161618'
};

export function withA(hex: string, alpha: number): string {
  const a = Math.max(0, Math.min(255, Math.round(alpha * 255)));
  return '#' + a.toString(16).padStart(2, '0') + hex.replace('#', '').toUpperCase();
}

export function mixHex(hex: string, other: string, t: number): string {
  return mix(hex, other, t);
}

function mix(hex: string, other: string, t: number): string {
  const a = hex.replace('#', '');
  const b = other.replace('#', '');
  let out = '';
  for (let i = 0; i < 3; i++) {
    const ca = parseInt(a.substr(i * 2, 2), 16);
    const cb = parseInt(b.substr(i * 2, 2), 16);
    const v = Math.round(ca + (cb - ca) * t);
    out += Math.max(0, Math.min(255, v)).toString(16).padStart(2, '0');
  }
  return '#' + out.toUpperCase();
}

export class CoverColors {
  private static cache: Map<string, Mood> = new Map();
  private static pending: string[] = [];

  static clear(): void {
    CoverColors.cache.clear();
    CoverColors.pending = [];
  }

  static cacheCount(): number {
    return CoverColors.cache.size;
  }

  static mood(url: string): Mood {
    const hit = CoverColors.cache.get(url);
    return hit !== undefined ? hit : FALLBACK;
  }

  static async of(url: string): Promise<Mood> {
    if (url.length === 0) {
      return FALLBACK;
    }
    const hit = CoverColors.cache.get(url);
    if (hit !== undefined) {
      return hit;
    }
    if (CoverColors.pending.indexOf(url) >= 0) {
      for (let wait = 0; wait < 80; wait++) {
        await new Promise<void>((resolve: Function) => { setTimeout(() => { resolve(); }, 100); });
        const cached = CoverColors.cache.get(url);
        if (cached !== undefined) {
          return cached;
        }
        if (CoverColors.pending.indexOf(url) < 0) {
          return FALLBACK;
        }
      }
      return FALLBACK;
    }
    CoverColors.pending.push(url);
    let mood = FALLBACK;
    try {
      mood = await CoverColors.fetch(url);
    } catch (_e) {
      const idx = CoverColors.pending.indexOf(url);
      if (idx >= 0) { CoverColors.pending.splice(idx, 1); }
      return FALLBACK;
    }
    CoverColors.cache.set(url, mood);
    const idx = CoverColors.pending.indexOf(url);
    if (idx >= 0) { CoverColors.pending.splice(idx, 1); }
    return mood;
  }

  private static async fetch(url: string): Promise<Mood> {
    const h = http.createHttp();
    let pixels: Uint8Array;
    let w = 0;
    let hh = 0;
    try {
      const r = await h.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: true
      });
      if (r.responseCode < 200 || r.responseCode >= 300) {
        return FALLBACK;
      }
      const src = image.createImageSource(r.result as ArrayBuffer);
      const pm = await src.createPixelMap({
        desiredSize: { width: 32, height: 32 }
      });
      const info = await pm.getImageInfo();
      w = info.size.width;
      hh = info.size.height;
      if (w <= 0 || hh <= 0) {
        pm.release();
        src.release();
        return FALLBACK;
      }
      const buf = new ArrayBuffer(w * hh * 4);
      await pm.readPixelsToBuffer(buf);
      pixels = new Uint8Array(buf);
      pm.release();
      src.release();
    } catch (_e) {
      return FALLBACK;
    } finally {
      h.destroy();
    }
    let sr = 0;
    let sg = 0;
    let sb = 0;
    let n = 0;
    let bestScore = -1;
    let br = 138;
    let bg = 138;
    let bb = 142;
    for (let i = 0; i + 3 < pixels.length; i += 4) {
      const cr = pixels[i];
      const cg = pixels[i + 1];
      const cb = pixels[i + 2];
      sr += cr;
      sg += cg;
      sb += cb;
      n++;
      const mx = Math.max(cr, cg, cb);
      const mn = Math.min(cr, cg, cb);
      const sat = mx <= 0 ? 0 : (mx - mn) / mx;
      const lum = (0.2126 * cr + 0.7152 * cg + 0.0722 * cb) / 255;
      if (lum < 0.12 || lum > 0.95) {
        continue;
      }
      const score = sat * 0.75 + (1 - Math.abs(lum - 0.5) * 1.2) * 0.25;
      if (score > bestScore) {
        bestScore = score;
        br = cr;
        bg = cg;
        bb = cb;
      }
    }
    if (n <= 0) {
      return FALLBACK;
    }
    const avgr = Math.round(sr / n);
    const avgg = Math.round(sg / n);
    const avgb = Math.round(sb / n);
    const toHex = (v: number): string => v.toString(16).padStart(2, '0');
    const vibrant = '#' + toHex(br) + toHex(bg) + toHex(bb);
    const soft = '#' + toHex(avgr) + toHex(avgg) + toHex(avgb);
    const vl = (0.2126 * br + 0.7152 * bg + 0.0722 * bb) / 255;
    const mood: Mood = {
      glow: mix(soft, vibrant, vl < 0.28 ? 0.55 : 0.75),
      soft: mix(soft, '#101012', 0.15),
      deep: mix(soft, '#050506', 0.55)
    };
    return mood;
  }
}
