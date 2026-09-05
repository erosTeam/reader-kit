const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

// Only used by host tests of the real platform-free ArkTS modules.
module.exports = name => {
  const previous = Module._extensions['.ets']
  Module._extensions['.ets'] = (target, file) => {
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    }).outputText
    target._compile(compiled, file)
  }
  try {
    return require(path.resolve(__dirname, '../reader-core/src/main/ets', `${name}.ets`))
  } finally {
    if (previous) Module._extensions['.ets'] = previous
    else delete Module._extensions['.ets']
  }
}
