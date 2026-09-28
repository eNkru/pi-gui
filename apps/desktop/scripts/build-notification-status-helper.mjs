import { execFile } from "node:child_process";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const desktopDir = path.resolve(scriptDir, "..");
const outputDir = path.join(desktopDir, "build", "native");
const helpers = [
  {
    sourcePath: path.join(desktopDir, "resources", "notification-status-helper.swift"),
    outputStem: "pi-gui-notification-status-helper",
  },
];

if (process.platform !== "darwin") {
  console.log("Skipping notification status helper build outside macOS.");
  process.exit(0);
}

// electron-builder copies build/native/<stem>-${arch} into each app via the
// `extraFiles` ${arch} macro, so emit one single-arch helper per slice. Code
// signing rejects a fat/universal helper dropped into a single-arch bundle.
const macSlices = [
  { arch: "arm64", target: "arm64-apple-macos11.0" },
  { arch: "x64", target: "x86_64-apple-macos11.0" },
];

await mkdir(outputDir, { recursive: true });
for (const helper of helpers) {
  await Promise.all(
    macSlices.map(({ arch, target }) =>
      execFileAsync(
        "xcrun",
        [
          "swiftc",
          helper.sourcePath,
          "-O",
          "-target",
          target,
          "-o",
          path.join(outputDir, `${helper.outputStem}-${arch}`),
        ],
        { cwd: desktopDir },
      ),
    ),
  );
  console.log(
    `Built native helpers for ${macSlices.map(({ arch }) => arch).join(" + ")} under ${outputDir}`,
  );
}
