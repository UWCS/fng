// plasmashell update script to do pinned taskbar icons
const launchers = [
    "applications:systemsettings.desktop",
    "preferred://filemanager",
    "applications:steam.desktop",
    "applications:librewolf.desktop",
    "applications:net.lutris.Lutris.desktop",
    "applications:org.prismlauncher.PrismLauncher.desktop",
    "applications:org.kde.konsole.desktop"
];

for (const panel of panels()) {
    for (const widget of panel.widgets()) {
        if (widget.type !== "org.kde.plasma.icontasks" && widget.type !== "org.kde.plasma.taskmanager") {
            continue;
        }

        widget.currentConfigGroup = ["General"];
        widget.writeConfig("launchers", launchers);
        // double write to mitigate stupid propagation issue
        widget.writeConfig("launchers", launchers);
        widget.reloadConfig();
    }
}
