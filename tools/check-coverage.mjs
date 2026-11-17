// The coverage check: reads what coverage.sh's busted run left in .coverage and
// fails unless every line (luacov) and every branch (test/helpers/coverage.lua) of the addon's own files ran.
//
//   node tools/check-coverage.mjs
//
// The addon's own files are LFGPlus/*.lua (not the embedded Libs/) and the data add-on's Lua. A file the specs never
// load counts as fully missed.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ADDON = fileURLToPath(new URL('..', import.meta.url));
const COVERAGE = join(ADDON, '.coverage');

/** Every production Lua file, as a path relative to addon/ with forward slashes. */
function productionFiles() {
    const files = [];
    const walk = dir => {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
            const path = join(dir, entry.name);
            if (entry.isDirectory()) walk(path);
            else if (entry.name.endsWith('.lua')) files.push(relative(ADDON, path).replaceAll('\\', '/'));
        }
    };
    for (const entry of readdirSync(ADDON, { withFileTypes: true })) {
        if (entry.isDirectory() && (entry.name === 'LFGPlus' || entry.name.startsWith('LFGPlus_Data_'))) walk(join(ADDON, entry.name));
    }
    return files.filter(f => !f.startsWith('LFGPlus/Libs/')).sort();
}

/** luacov's report: for each file, the line numbers it marks as never run. */
function missedLines(report) {
    const missed = new Map();
    const lines = report.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        if (!/^={20,}$/.test(lines[i]) || !/^={20,}$/.test(lines[i + 2] ?? '')) continue;
        const file = lines[i + 1].trim();
        if (file === 'Summary') break;
        const list = [];
        let n = 0;
        for (let j = i + 3; j < lines.length && !/^={20,}$/.test(lines[j]); j++) {
            n++;
            if (/^\*+0 /.test(lines[j])) list.push(n);
        }
        missed.set(file, list);
    }
    return missed;
}

const reportPath = join(COVERAGE, 'luacov.report.out');
const branchesPath = join(COVERAGE, 'lua-branches.tsv');
if (!existsSync(reportPath) || !existsSync(branchesPath)) {
    console.error('No addon coverage data: run ./coverage.sh first.');
    process.exit(1);
}

const lineMisses = missedLines(readFileSync(reportPath, 'utf8'));
const branchMisses = new Map();
const branchTotals = new Map();
for (const row of readFileSync(branchesPath, 'utf8').split('\n').filter(Boolean)) {
    const [file, line, kind, hits] = row.split('\t');
    branchTotals.set(file, (branchTotals.get(file) ?? 0) + 1);
    if (hits === '0') branchMisses.set(file, [...(branchMisses.get(file) ?? []), `${line} (${kind})`]);
}

let failed = false;
console.log('Addon Lua coverage (lines from luacov, branches from test/helpers/coverage.lua)');
for (const file of productionFiles()) {
    const lines = lineMisses.get(file);
    const branches = branchMisses.get(file) ?? [];
    if (!lines) {
        console.log(`  FAIL ${file}: never loaded by any spec`);
        failed = true;
    } else if (lines.length > 0 || branches.length > 0) {
        if (lines.length > 0) console.log(`  FAIL ${file}: lines never run: ${lines.join(', ')}`);
        if (branches.length > 0) console.log(`  FAIL ${file}: branches never taken: ${branches.join(', ')}`);
        failed = true;
    } else {
        console.log(`  ok   ${file} (${branchTotals.get(file) ?? 0} branches)`);
    }
}
if (failed) {
    console.error('Addon coverage is below 100% of lines and branches.');
    process.exit(1);
}
console.log('Addon coverage: 100% of lines and branches.');
