const fs = require('fs');
const path = require('path');

// Character replacements
const characterReplacements = {
  '\u2500': '-',     // Horizontal box drawing character
  '\u2502': '|',     // Vertical box drawing character
  '\u2514': '+',     // Bottom-left corner
  '\u250C': '+',     // Top-left corner
  '\u2510': '+',     // Top-right corner
  '\u2518': '+',     // Bottom-right corner
  '\u251C': '+',     // T-junction
  '\u2524': '+',     // T-junction
  '\u2192': '->',    // Right arrow
  '\u2022': '*',     // Bullet
  '\u2026': '...'    // Ellipsis
};

// Normalize content
function normalizeContent(content) {
  let normalizedContent = content;
  for (const [unicode, ascii] of Object.entries(characterReplacements)) {
    normalizedContent = normalizedContent.replace(new RegExp(unicode, 'g'), ascii);
  }
  return normalizedContent;
}

// Create dist directory
const distDir = path.join(__dirname, 'dist');
const distScriptsDir = path.join(distDir, 'scripts');

if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir);
}
if (!fs.existsSync(distScriptsDir)) {
  fs.mkdirSync(distScriptsDir);
}

// Copy and normalize scripts
const scriptsDir = path.join(__dirname, 'scripts');
const files = fs.readdirSync(scriptsDir);

files.forEach(file => {
  const filePath = path.join(scriptsDir, file);
  const distPath = path.join(distScriptsDir, file);
  const distRootPath = path.join(distDir, file);
  
  if (file.endsWith('.sh') || file.endsWith('.txt')) {
    // Normalize text files
    const content = fs.readFileSync(filePath, 'utf8');
    const normalized = normalizeContent(content);
    fs.writeFileSync(distPath, normalized);
    // Also copy to root for direct access
    fs.writeFileSync(distRootPath, normalized);
    console.log(`Normalized: ${file}`);
  } else {
    // Copy other files as-is
    fs.copyFileSync(filePath, distPath);
    fs.copyFileSync(filePath, distRootPath);
    console.log(`Copied: ${file}`);
  }
});

// Copy index.html
fs.copyFileSync(
  path.join(__dirname, 'public', 'index.html'),
  path.join(distDir, 'index.html')
);

console.log('\nBuild complete! Deploy the "dist" directory to any static host.');