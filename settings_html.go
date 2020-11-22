package main

// ToDo: Store source in HTML and code gen the variable
var settingsHTMLTmpl = `
<html>
	<head>
		<title>GitHub Notify</title>
		<link rel="shortcut icon" type="image/svg+xml" href="https://github.githubassets.com/favicons/favicon.svg">
		<link rel="apple-touch-icon" sizes="180x180" href="https://github.githubassets.com/apple-touch-icon-180x180.png">
		<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-alpha3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-CuOF+2SnTUfTwSZjCXf01h7uYhfOBuxIhGKPbfEJ3+FqH/s6cIFN9bGr1HmAg4fQ" crossorigin="anonymous">
		<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-alpha3/dist/js/bootstrap.bundle.min.js" integrity="sha384-popRpmFF9JQgExhfw5tZT4I9/CI5e2QcuUZPOVXb1m7qUmeR2b50u+YFEYe1wgzy" crossorigin="anonymous"></script>
		<style type="text/css">
			.no-select {
				user-select: none;
				-o-user-select:none;
				-moz-user-select: none;
				-khtml-user-select: none;
				-webkit-user-select: none;
			}
		</style>
	</head>
	<body class="no-select">
		<div class="settings-form">
			<div class="modal-header">
				<h5 class="modal-title" id="exampleModalLabel">Settings</h5>
				<button type="button" class="btn-close" data-dismiss="modal" aria-label="Close" onclick="window.close()"></button>
			</div>
			<div class="modal-body">
				<div class="mb-3">
					<label for="githubToken" class="form-label">GitHub token</label>
					<input type="password" class="form-control" id="githubToken">
				</div>
				<div class="mb-3">
					<label for="updateFrequency" class="form-label">Update frequency</label>
					<select class="form-select" id="updateFrequency">
						<option value="10s">High</option>
						<option value="30s">Medium</option>
						<option value="120s">Low</option>
					</select>
				</div>
				<div class="form-check" style="display: none;">
					<input class="form-check-input" type="checkbox" value="" id="desktopNotifications">
					<label class="form-check-label" for="desktopNotifications">
						Show desktop notifications
					</label>
				</div>
				<div class="mb-3">
					<label for="favouriteRepos" class="form-label">Favourite repositiries</label>
					<textarea class="form-control" id="favouriteRepos" rows="2"></textarea>
					<div class="form-text">Comma separated list of repositories.</div>
				</div>
			</div>
			<div class="modal-footer">
				<button type="button" class="btn btn-secondary" data-dismiss="modal" onclick="window.close()">Close</button>
				<button type="button" class="btn btn-primary" onclick="save()">Save</button>
			</div>
		</div>
		<script type="text/javascript">

			// Restore default values
			Object.keys(settings).forEach((key) => {
				const el = document.getElementById(key);
				if (el && typeof settings[key] === "string") {
					try {
						el.value = settings[key] || '';
					} catch {}
				}
			});
			// document.getElementById("desktopNotifications").checked = desktopNotifications;
			document.getElementById("favouriteRepos").value = settings.favouriteRepos.join(", ");

			// Settings save handler
			function save() {
				const data = {
					githubToken: document.getElementById("githubToken").value,
					updateFrequency: document.getElementById("updateFrequency").value,
					favouriteRepos: [ ...new Set(
						document.getElementById("favouriteRepos").value
							.replace(/;/g, ",").split(",").map((repo) => repo.trim())
					)],
					// desktopNotifications: document.getElementById("desktopNotifications").checked
				};
				saveSettings(JSON.stringify(data));
			}

			// Adapt window size handler
			const fitWindowToFormSize = () => {
				if (!window["formSize"]) {
					const form = document.querySelector(".settings-form");
					if (form) {
						window["formSize"] = {
							width: form.clientWidth,
							height: form.clientHeight + 30
						};
					}
				}
				if (window["formSize"]) {
					const { width, height } = window["formSize"];
					window.resizeTo(width, height);
				}
			};

			// Center dialog window
			const centerDialogWindow = () => {
				window.moveTo(
					(screen.availWidth - window.innerWidth)/2,
					(screen.availHeight - window.innerHeight)/2
				);
			};

			// Window configuration
			// window.addEventListener("contextmenu", function(e) { e.preventDefault(); });
			fitWindowToFormSize();
			// centerDialogWindow();

		</script>
	</body>
</html>
`
