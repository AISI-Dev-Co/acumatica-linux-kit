# Acumatica Linux Kit

Develop Acumatica customizations from Linux. Keep your editor, Git checkout, browser, and coding agent on Linux. A local Windows VM runs Acumatica, IIS, and the Windows build tools.

The kit gives your agent the setup playbook and tools to find the code behind a screen, build a customization ZIP, run Acuminator, and test changes on a separate Acumatica site without disturbing your main dev instance.

## Send in the agent

Clone the repo, open it with your coding agent, and give it this:

> Set up Acumatica on this machine. Read AGENTS.md and the setup skill, then do the work instead of giving me a checklist. Reuse a compatible setup if there is one. Troubleshoot what you can, ask me for access or approval when needed, and verify that I can open the dev site and read its source from Linux. Tell me what worked and what's still blocked.

The [setup skill](.agents/skills/setup/SKILL.md) is for the agent. You don't need to memorise the right IIS checkboxes or type a PowerShell script into a VM console. If Windows needs a restart, a licence needs accepting, or the agent can't get past the guest console, it should tell you exactly where it got stuck and what it needs from you.

## What you need

- An x86-64 Linux machine with hardware virtualisation (KVM) and enough RAM and disk for Windows and SQL Server.
- Permission to set up Docker Engine with Compose and configure local mounts.
- Authorised Windows and Acumatica access. The kit doesn't ship installers, VM images, or licences.

No Omarchy or existing Windows VM required. The kit uses Dockur to create the guest. Windows owns the Acumatica data disk while it's running. Linux reads the site over a local share, then can mount the disk directly once Windows is stopped.

## What runs together

- **Windows and IIS** run Acumatica. The kit connects the guest to the Linux SQL Server container and forwards the dev site to your Linux browser.
- **SQL Server** keeps its data in a persistent volume. Each Acumatica site has its own database, IIS pool, and website files. The VM and SQL Server are shared.
- **n8n** is an optional sidecar with its own persistent data. It connects to the default Acumatica site. Ask the agent to bring it up and verify the connection if you're working on an integration. Workflow credentials are configured separately.

For another Acumatica instance, ask your agent to create one for the supported build you need. It can switch between sites, run them side by side, and checkpoint or reset a named test site. See the [runtime](.agents/skills/environment/references/docker-sidecars.md) and [instance](.agents/skills/environment/references/instances.md) skills.

## When something doesn't fit

Let the agent diagnose it before changing the host or reinstalling anything. If the kit needs a fix, have the agent check the [issue tracker](https://github.com/AISI-Dev-Co/acumatica-linux-kit/issues). A useful bug report includes your Linux distro, the setup stage that failed, the relevant error with secrets removed, and what fixed it if you found a fix. That's how the next agent gets past it without asking you.
