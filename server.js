const express = require('express');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3000;

// Replacements for normalizing special characters on-the-fly
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

// Function to normalize content
function normalizeContent(content) {
  let normalizedContent = content;
  
  // Replace each special character with its ASCII alternative
  for (const [unicode, ascii] of Object.entries(characterReplacements)) {
    normalizedContent = normalizedContent.replace(new RegExp(unicode, 'g'), ascii);
  }
  
  return normalizedContent;
}

// Detect if request is from curl or wget
function isScriptRequest(req) {
  const userAgent = req.headers['user-agent'] || '';
  return userAgent.includes('curl') || 
         userAgent.includes('Wget') ||
         userAgent.includes('fetch');
}

// Serve static files from the 'public' directory
app.use(express.static(path.join(__dirname, 'public')));

// Serve scripts with on-the-fly normalization
app.get('/:scriptName', (req, res) => {
  const scriptName = req.params.scriptName;
  const scriptPath = path.join(__dirname, 'scripts', scriptName);
  
  // Check if the requested file exists
  if (fs.existsSync(scriptPath)) {
    // For shell scripts and text files, read, normalize, and serve with proper headers
    if (scriptName.endsWith('.sh') || scriptName.endsWith('.txt')) {
      fs.readFile(scriptPath, 'utf8', (err, data) => {
        if (err) {
          return res.status(500).send('Error reading script file');
        }
        
        // Normalize the content
        const normalizedContent = normalizeContent(data);
        
        // Set appropriate headers
        res.setHeader('Content-Type', 'text/plain; charset=utf-8');
        
        // For curl/wget, make it executable, otherwise display inline
        if (isScriptRequest(req)) {
          // Content-Disposition set to attachment for curl/wget
          res.setHeader('Content-Disposition', `attachment; filename="${scriptName}"`);
        } else {
          // Content-Disposition set to inline for browser viewing
          res.setHeader('Content-Disposition', `inline; filename="${scriptName}"`);
        }
        
        // Send the normalized content
        res.send(normalizedContent);
      });
    } else {
      // For non-script files, just send as-is
      res.sendFile(scriptPath);
    }
  } else {
    // If file not found, check if it's a request for the index page
    if (scriptName === 'index.html' || scriptName === '') {
      res.sendFile(path.join(__dirname, 'public', 'index.html'));
    } else {
      res.status(404).send('File not found');
    }
  }
});

// View script content with syntax highlighting or raw display
app.get('/raw/:scriptName', (req, res) => {
  const scriptName = req.params.scriptName;
  const scriptPath = path.join(__dirname, 'scripts', scriptName);
  
  if (fs.existsSync(scriptPath)) {
    if (scriptName.endsWith('.sh') || scriptName.endsWith('.txt')) {
      fs.readFile(scriptPath, 'utf8', (err, data) => {
        if (err) {
          console.error('Error reading file:', err);
          return res.status(500).send('Error reading script file');
        }
        
        console.log(`Reading ${scriptPath}, data length: ${data.length}`);
        const normalizedContent = normalizeContent(data);
        console.log(`After normalization, content length: ${normalizedContent.length}`);
        
        // For /raw/ endpoint, display as text for viewing
        res.setHeader('Content-Type', 'text/plain; charset=utf-8');
        res.setHeader('Content-Disposition', `inline; filename="${scriptName}"`);
        
        res.send(normalizedContent);
      });
    } else {
      res.sendFile(scriptPath);
    }
  } else {
    res.status(404).send('File not found');
  }
});

// Default route serves the index.html
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Access your scripts at: http://localhost:${PORT}/[script-name]`);
  console.log(`View script content: http://localhost:${PORT}/raw/[script-name]`);
});