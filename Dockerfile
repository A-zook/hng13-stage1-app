# Use a stable Node.js image
FROM node:20-slim

# Set the working directory inside the container
WORKDIR /app

# Copy dependency files and install packages
COPY package*.json ./
RUN npm install --omit=dev

# Copy the rest of the application code
COPY . .

# Expose the internal port (must match the PORT variable in server.js)
EXPOSE 8080  

# Command to run the application
CMD ["node", "server.js"]
