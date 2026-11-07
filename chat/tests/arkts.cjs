const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const sdk = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'tools/hvigor/hvigor/node_modules/typescript'));
const originals = Module._load;
const assets = new Map();
const asset = {
  Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, CONFLICT_RESOLUTION: 5 },
  Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, ReturnType: { ALL: 0 },
  ConflictResolution: { OVERWRITE: 0 }, ErrorCode: { NOT_FOUND: 24000002 },
  async query(q) { const v = assets.get(Buffer.from(q.get(1)).toString()); if (!v) throw Object.assign(new Error('missing'), {code: 24000002}); return [v]; },
  async add(q) { assets.set(Buffer.from(q.get(1)).toString(), new Map(q)); },
  async remove(q) { assets.delete(Buffer.from(q.get(1)).toString()); }
};
let scenario = null;
const http = { RequestMethod: { POST: 'POST' }, createHttp() { return scenario(); } };
const util = {
  TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
  TextDecoder: { create(label, options) { const decoder = new TextDecoder(label, options); return { decodeToString: (b, o) => decoder.decode(b, o) }; } }
};
const fileIo = {
  OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, TRUNC: fs.constants.O_TRUNC },
  accessSync: fs.existsSync, readTextSync: f => fs.readFileSync(f, 'utf8'),
  openSync: (f, flags) => ({ fd: fs.openSync(f, flags, 0o600) }),
  closeSync: file => fs.closeSync(file.fd),
  writeSync: (fd, b) => fs.writeSync(fd, Buffer.from(b)), fsyncSync: fs.fsyncSync,
  copyFileSync: fs.copyFileSync, renameSync: fs.renameSync
};
Module._load = function(name, parent, isMain) {
  if (name === '@kit.ArkTS') return { util };
  if (name === '@kit.NetworkKit') return { http };
  if (name === '@kit.CoreFileKit') return { fileIo };
  if (name === '@kit.AssetStoreKit') return { asset };
  if (name === '@kit.BasicServicesKit') return {};
  return originals.apply(this, arguments);
};
Module._extensions['.ets'] = (mod, filename) => {
  const source = fs.readFileSync(filename, 'utf8');
  const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } });
  mod._compile(result.outputText, filename);
};
module.exports = { load: relative => require(path.resolve(__dirname, '../entry/src/main/ets', relative)),
  setNetwork: factory => { scenario = factory; }, assets, fileIo };
