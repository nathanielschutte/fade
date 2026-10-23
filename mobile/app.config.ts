import type { ExpoConfig } from "expo/config";

// The app's version, per release (SemVer, like the server). EAS sets the build
// number on its own. See docs/design/mobile.md and docs/operations/releasing.md.
const VERSION = "0.1.0";

const config: ExpoConfig = {
  name: "napsack",
  slug: "napsack",
  version: VERSION,
  orientation: "portrait",
  icon: "./assets/icon.png",
  userInterfaceStyle: "dark",
  backgroundColor: "#1b2822",
  ios: {
    // Permanent once the app exists in App Store Connect.
    bundleIdentifier: "com.getattr.napsack",
    supportsTablet: false,
  },
  plugins: ["react-native-quick-crypto", "expo-secure-store"],
  extra: {
    eas: { projectId: "2d59c0e5-a585-4859-8a80-a5acfad847e7" },
  },
};

export default config;
