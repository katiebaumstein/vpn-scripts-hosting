/**
 * Script to normalize special characters in the script files
 * Replaces Unicode box-drawing characters with ASCII alternatives
 */
const fs = require('fs');
const path = require('path');

// Directory containing the scripts
const scriptsDir = path.join(__dirname, '..', 'scripts');
// Directory to store normalized scripts
const normalizedDir = path.join(__dirname, '..', 'scripts-normalized');

// Create normalized directory if it doesn't exist
if (!fs.existsSync(normalizedDir)) {
  fs.mkdirSync(normalizedDir, { recursive: true });
}

// Character replacement map using unicode escape sequences
const replacements = {
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

// Function to normalize content
function normalizeContent(content) {
  let normalizedContent = content;
  
  // Replace each special character with its ASCII alternative
  for (const [unicode, ascii] of Object.entries(replacements)) {
    normalizedContent = normalizedContent.replace(new RegExp(unicode, 'g'), ascii);
  }
  
  return normalizedContent;
}

// Process all script files
fs.readdir(scriptsDir, (err, files) => {
  if (err) {
    console.error('Error reading scripts directory:', err);
    return;
  }
  
  files.forEach(file => {
    if (file.endsWith('.sh')) {
      const filePath = path.join(scriptsDir, file);
      const normalizedPath = path.join(normalizedDir, file);
      
      fs.readFile(filePath, 'utf8', (err, data) => {
        if (err) {
          console.error(`Error reading file ${file}:`, err);
          return;
        }
        
        const normalizedContent = normalizeContent(data);
        
        fs.writeFile(normalizedPath, normalizedContent, 'utf8', (err) => {
          if (err) {
            console.error(`Error writing normalized file ${file}:`, err);
            return;
          }
          console.log(`Normalized ${file}`);
        });
      });
    }
  });
});

console.log('Script normalization process started. Normalized scripts will be in the scripts-normalized directory.');