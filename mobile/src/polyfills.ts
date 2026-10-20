// Must run before anything touches `crypto`: index.ts imports this first.
// react-native-quick-crypto installs a native WebCrypto as `global.crypto`,
// which is what shared/crypto/crypto.js uses on every platform.
import { install } from "react-native-quick-crypto";

install();
