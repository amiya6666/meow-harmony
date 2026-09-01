export function errText(e: Object): string {
  const rec = e as Record<string, string | number>;
  const msg = rec['message'] !== undefined ? '' + rec['message'] : '';
  const code = rec['code'] !== undefined ? '' + rec['code'] : '';
  if (msg.length > 0 && msg.indexOf('[object ') < 0) return code.length > 0 ? code + ' ' + msg : msg;
  if (code.length > 0) return 'Error ' + code;
  return 'Unknown error';
}
