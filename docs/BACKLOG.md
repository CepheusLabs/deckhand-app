# Backlog

## Backup UI

- Show the friendly disk name during eMMC backup progress. The pre-copy card
  already shows values like `Generic STORAGE DEVICE`, but the progress footer
  can still show the raw Windows path such as `\\.\PHYSICALDRIVE3`. Use the
  same `diskDisplayName`/summary path used by disk selection, with the raw
  device path only as secondary technical detail if needed.
