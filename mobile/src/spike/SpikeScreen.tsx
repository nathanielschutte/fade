// Milestone 1 (docs/mobile.md): prove the shared crypto runs on a real iPhone
// and produces exactly the pinned bytes, and that 600,000-round PBKDF2 is fast
// enough to sign in with. Runs every check in shared/crypto/vector-checks.js.
import { useCallback, useEffect, useState } from "react";
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import Constants from "expo-constants";

// Shared with the web client and Node's CI test. Plain JS modules.
import * as e2e from "../../../shared/crypto/crypto.js";
import { runVectorChecks, type CheckResult } from "../../../shared/crypto/vector-checks.js";
import format1 from "../../../tests/vectors/format1.json";
import format2 from "../../../tests/vectors/format2.json";
import recovery from "../../../tests/vectors/recovery.json";
import texts2 from "../../../tests/vectors/texts2.json";
import group3 from "../../../tests/vectors/group3.json";
import { colors } from "../theme";

export default function SpikeScreen() {
  const [results, setResults] = useState<CheckResult[]>([]);
  const [running, setRunning] = useState(false);
  const [crash, setCrash] = useState<string | null>(null);

  const run = useCallback(async () => {
    setRunning(true);
    setCrash(null);
    setResults([]);
    try {
      await runVectorChecks(e2e, { format1, format2, recovery, texts2, group3 }, (r) => {
        console.log(`${r.ok ? "ok  " : "FAIL"} ${r.name} (${r.ms} ms)${r.error ? `: ${r.error}` : ""}`);
        setResults((prev) => [...prev, r]);
      });
    } catch (err) {
      setCrash(String((err as Error)?.message ?? err));
    } finally {
      setRunning(false);
    }
  }, []);

  useEffect(() => {
    run();
  }, [run]);

  const failed = results.filter((r) => !r.ok).length;
  const pbkdf2 = results.find((r) => r.name === "password derives the vector's auth key");
  const summary = running
    ? `Running… ${results.length} done`
    : crash
      ? "Crashed"
      : failed
        ? `${failed} of ${results.length} failed`
        : `All ${results.length} checks passed`;

  return (
    <ScrollView style={styles.page} contentContainerStyle={styles.content}>
      <Text style={styles.title}>napsack crypto check</Text>
      <Text style={styles.meta}>
        iOS {String(Platform.Version)} · app {Constants.expoConfig?.version ?? "?"}
      </Text>
      <View style={[styles.summary, !running && (failed || crash) ? styles.bad : null]}>
        <Text style={styles.summaryText}>{summary}</Text>
        {pbkdf2 ? (
          <Text style={styles.meta}>Sign-in key stretch (PBKDF2, 600,000 rounds): {pbkdf2.ms} ms</Text>
        ) : null}
      </View>
      {crash ? <Text style={styles.error}>{crash}</Text> : null}
      {results.map((r) => (
        <View key={r.name} style={styles.row}>
          <Text style={[styles.mark, r.ok ? styles.ok : styles.fail]}>{r.ok ? "✓" : "✗"}</Text>
          <View style={styles.rowText}>
            <Text style={styles.name}>{r.name}</Text>
            {r.error ? <Text style={styles.error}>{r.error}</Text> : null}
          </View>
          <Text style={styles.ms}>{r.ms} ms</Text>
        </View>
      ))}
      <Pressable style={styles.button} onPress={run} disabled={running}>
        <Text style={styles.buttonText}>{running ? "Running…" : "Run again"}</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: colors.ink },
  content: { padding: 20, paddingTop: 72, paddingBottom: 48, gap: 6 },
  title: { color: colors.paper, fontSize: 24, fontWeight: "700" },
  meta: { color: colors.fixer, fontSize: 13 },
  summary: { backgroundColor: colors.wash, borderRadius: 14, padding: 14, marginVertical: 12, gap: 4 },
  bad: { borderWidth: 1, borderColor: colors.danger },
  summaryText: { color: colors.paper, fontSize: 17, fontWeight: "600" },
  row: {
    flexDirection: "row", alignItems: "flex-start", gap: 10, paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.rule,
  },
  mark: { width: 18, fontSize: 16, fontWeight: "700" },
  ok: { color: colors.sage },
  fail: { color: colors.danger },
  rowText: { flex: 1, gap: 2 },
  name: { color: colors.paper, fontSize: 15 },
  ms: { color: colors.fixer, fontSize: 13 },
  error: { color: colors.danger, fontSize: 13 },
  button: { marginTop: 20, backgroundColor: colors.sage, borderRadius: 999, paddingVertical: 12, alignItems: "center" },
  buttonText: { color: colors.onSage, fontWeight: "700", fontSize: 16 },
});
