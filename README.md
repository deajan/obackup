obackup
=======

A local or remote file & database backup script tailored for multiple virtualhost backups. Yet it actually works for a lot of backup tasks.

OBackup is designed from ground to make the backup process as reliable as possible.
It divides the whole backup process into tasks, allowing each task to execute for a certain amount of time.
If a task doesn't finish in time, it's stopped and the next task is processed.
Before a task gets stopped, a first warning message is generated telling the task takes too long.
Every action gets logged, and at the end of the backup process, if there was a warning, a stopped task or an error an email will be sent.

Obackup manages to backup MariaDB / MySQL databases and files (with or without root rights).
