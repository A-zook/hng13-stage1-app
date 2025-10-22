const express = require('express');
const app = express();
// This is the internal container port that NGINX will proxy to
const PORT = 8080;

app.get('/', (req, res) => {
  res.send(`
    <!DOCTYPE html>
    <html lang="en">
    <head><title>HNG Stage 1 Success</title>
    <style>
      body { font-family: sans-serif; text-align: center; margin-top: 50px; background-color: #f0f4f8; color: #333; }
      .container { border: 2px solid #007bff; padding: 30px; border-radius: 10px; display: inline-block; background-color: white; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
      h1 { color: #007bff; }
    </style>
    </head>
    <body>
      <div class="container">
        <h1>Deployment Successful via Automated Script!</h1>
        <p>This is the application running inside the Docker container on Port ${PORT}.</p>
        <p>NGINX is correctly reverse proxying Port 80 to this container.</p>
      </div>
    </body>
    </html>
  `);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(` Server is running and accessible on port ${PORT}`);
});