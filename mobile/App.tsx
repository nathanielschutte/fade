import { StatusBar } from "expo-status-bar";

import SpikeScreen from "./src/spike/SpikeScreen";

// For now the app is the crypto spike (milestone 1 in docs/mobile.md).
// Sign-in and chats come next.
export default function App() {
  return (
    <>
      <SpikeScreen />
      <StatusBar style="light" />
    </>
  );
}
