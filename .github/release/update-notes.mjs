const SECTION_ORDER = [
  "BREAKING CHANGES",
  "Features",
  "Bug Fixes",
  "Performance Improvements",
  "Reverts",
];
const SECTION_TITLES = { "BREAKING CHANGES": "Important Changes" };

function cleanItem(item) {
  return item
    .replace(/,\s*closes(?:\s+\[[^\]]*#\d+\]\([^)]*\))+/gi, "")
    .replace(/\s*\(\[[^\]]*#\d+\]\([^)]*\)\)/g, "")
    .replace(/\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)/g, "")
    .replace(/^\* \*\*[^*]+:\*\* /, "* ")
    .replace(
      /^\* (\p{Ll})(?=\P{Lu}*?(?:\s|$))/u,
      (_, first) => `* ${first.toUpperCase()}`,
    );
}

export function forUpdateWindow(notes) {
  const sections = [];
  let blank = false;
  for (const line of notes.split("\n")) {
    const heading = line.match(/^#{3,}\s+(.+?)\s*$/);
    if (heading) {
      sections.push({ title: heading[1], items: [] });
    } else if (line.trim() === "") {
      blank = true;
      continue;
    } else if (sections.length > 0 && !line.startsWith("#")) {
      const { items } = sections[sections.length - 1];
      if (line.startsWith("* ") || items.length === 0) {
        items.push(line);
      } else {
        items[items.length - 1] += `${blank ? "\n\n" : "\n"}  ${line}`;
      }
    }
    blank = false;
  }
  const rank = (title) => {
    const index = SECTION_ORDER.indexOf(title);
    return index === -1 ? SECTION_ORDER.length : index;
  };
  const body = sections
    .filter(({ items }) => items.length > 0)
    .sort((a, b) => rank(a.title) - rank(b.title))
    .map(({ title, items }) =>
      [
        `### ${SECTION_TITLES[title] ?? title}`,
        "",
        ...items.map(cleanItem),
      ].join("\n"),
    )
    .join("\n\n");
  return body === "" ? notes : body;
}
