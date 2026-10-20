import "./src/polyfills"; // first: installs native WebCrypto as global.crypto

import { registerRootComponent } from "expo";

import App from "./App";

registerRootComponent(App);
