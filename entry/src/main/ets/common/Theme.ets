export interface Theme {
  bg: string;
  card: string;
  chip: string;
  chipActiveBg: string;
  chipActiveText: string;
  text: string;
  text2: string;
  sub: string;
  sub2: string;
  like: string;
  imgBg: string;
  barGlass: string;
  barLine: string;
  sheetBg: string;
  sheetText: string;
  sheetSub: string;
  sheetBtn: string;
  sheetDiv: string;
  handle: string;
  playBg: string;
  playGlyph: string;
  sliderTrack: string;
  toast: string;
  tabGlow: string;
  lyricInactive: string;
  glowK: number;
}

export const DARK_THEME: Theme = {
  bg: '#000000',
  card: '#1C1C1E',
  chip: '#2C2C2E',
  chipActiveBg: '#3A3A3C',
  chipActiveText: '#FFFFFF',
  text: '#FFFFFF',
  text2: '#FFFFFF',
  sub: '#B3FFFFFF',
  sub2: '#80FFFFFF',
  like: '#FF6B7A',
  imgBg: '#1A1614',
  barGlass: '#1C1C1E',
  barLine: '#33FFFFFF',
  sheetBg: '#161618',
  sheetText: '#FFFFFF',
  sheetSub: '#99FFFFFF',
  sheetBtn: '#2C2C2E',
  sheetDiv: '#3A3A3C',
  handle: '#636366',
  playBg: '#2C2C2E',
  playGlyph: '#FFFFFF',
  sliderTrack: '#66FFFFFF',
  toast: '#FFFFFF',
  tabGlow: '#40FFFFFF',
  lyricInactive: '#73FFFFFF',
  glowK: 1
};

export const LIGHT_THEME: Theme = {
  bg: '#F5F5F8',
  card: '#FFFFFF',
  chip: '#E9E9EF',
  chipActiveBg: '#E5E5EA',
  chipActiveText: '#000000',
  text: '#000000',
  text2: '#000000',
  sub: '#99000000',
  sub2: '#66000000',
  like: '#E0485A',
  imgBg: '#E9E9EE',
  barGlass: '#FDFDFF',
  barLine: '#33000000',
  sheetBg: '#FFFFFF',
  sheetText: '#000000',
  sheetSub: '#80000000',
  sheetBtn: '#F0F0F4',
  sheetDiv: '#E8E8EE',
  handle: '#8E8E93',
  playBg: '#FFFFFF',
  playGlyph: '#000000',
  sliderTrack: '#52000000',
  toast: '#000000',
  tabGlow: '#2E000000',
  lyricInactive: '#66000000',
  glowK: 0.85
};
