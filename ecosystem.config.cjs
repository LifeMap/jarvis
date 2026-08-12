const path = require("node:path");

module.exports = {
  apps: [
    {
      // Requires `npm run build` in admin/ beforehand (and after every deploy).
      name: "jarvis-admin",
      script: "npm",
      args: "run start",
      cwd: path.join(__dirname, "admin"),
      autorestart: true,
      watch: false,
    },
    {
      // Requires `npm run build` in web/ beforehand (and after every deploy).
      name: "jarvis-web",
      script: "npm",
      args: "run start",
      cwd: path.join(__dirname, "web"),
      autorestart: true,
      watch: false,
    },
  ],
};
