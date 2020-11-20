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
					<label for="githubToken" class="form-label">GitHub Token</label>
					<input type="password" class="form-control" id="githubToken">
				</div>
				<div class="mb-3">
					<label for="updateFrequency" class="form-label">Update Frequency</label>
					<select class="form-select" id="updateFrequency">
						<option value="10s">High</option>
						<option value="30s">Medium</option>
						<option value="120s">Low</option>
					</select>
				</div>
			</div>
			<div class="modal-footer">
				<button type="button" class="btn btn-secondary" data-dismiss="modal" onclick="window.close()">Close</button>
				<button type="button" class="btn btn-primary" onclick="save()">Save</button>
			</div>
		</div>
		<script type="text/javascript">

			// Settings save handler
			function save() {
				const data = {
					githubToken: document.getElementById("githubToken").value,
					updateFrequency: document.getElementById("updateFrequency").value
				};
				saveSettings(JSON.stringify(data));
			}

			// Restore default values
			const formData = { githubToken, updateFrequency };
			Object.keys(formData).forEach((key) => {
				const el = document.getElementById(key);
				if (el) {
					el.value = formData[key] || '';
				}
			});

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

			const centerDialogWindow = () => {
				window.moveTo(
					(screen.availWidth - window.innerWidth)/2,
					(screen.availHeight - window.innerHeight)/2
				);
			};

			// Window configuration
			window.addEventListener("contextmenu", function(e) { e.preventDefault(); });
			fitWindowToFormSize();
			// centerDialogWindow();

		</script>
	</body>
</html>
`
