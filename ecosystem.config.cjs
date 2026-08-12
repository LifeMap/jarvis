const path = require("node:path");

module.exports = {
  apps: [
    {
      name: "jarvis-admin",
      script: "npm",
      args: "run dev",
      cwd: path.join(__dirname, "admin"),
      autorestart: true,
      watch: false,
    },
    {
      name: "jarvis-web",
      script: "npm",
      args: "run dev",
      cwd: path.join(__dirname, "web"),
      autorestart: true,
      watch: false,
    },
  ],
};
