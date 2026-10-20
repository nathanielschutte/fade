// The app bundles code from outside mobile/: shared/ (the crypto every client
// uses) and tests/vectors/ (the pinned bytes the spike checks). Metro only
// sees files under watched folders, so add them.
const path = require("path");
const { getDefaultConfig } = require("expo/metro-config");

const root = path.resolve(__dirname, "..");
const config = getDefaultConfig(__dirname);

config.watchFolders = [path.join(root, "shared"), path.join(root, "tests", "vectors")];

module.exports = config;
