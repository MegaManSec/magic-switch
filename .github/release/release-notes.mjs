import { randomUUID } from "node:crypto";
import { appendFileSync } from "node:fs";
import semanticRelease from "semantic-release";
import { forUpdateWindow } from "./update-notes.mjs";

const result = await semanticRelease({ dryRun: true, ci: false });
if (!result || result.nextRelease.version !== process.env.VERSION) {
  console.error(
    `::error::semantic-release would release ${result ? result.nextRelease.version : "nothing"}, not ${process.env.VERSION}.`,
  );
  process.exit(1);
}

const delimiter = `NOTES_${randomUUID()}`;
appendFileSync(
  process.env.GITHUB_OUTPUT,
  `release-notes<<${delimiter}\n${forUpdateWindow(result.nextRelease.notes)}\n${delimiter}\n`,
);
