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
	</head>
	<body>
		<div class="modal-header">
			<h5 class="modal-title" id="exampleModalLabel">Settings</h5>
			<button type="button" class="btn-close" data-dismiss="modal" aria-label="Close" onclick="window.close()"></button>
		</div>
		<div class="modal-body">
			<form>
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
			</form>
		</div>
		<div class="modal-footer">
			<button type="button" class="btn btn-secondary" data-dismiss="modal" onclick="window.close()">Close</button>
			<button type="button" class="btn btn-primary" onclick="save()">Save</button>
		</div>
		<script type="text/javascript">
			function save() {
				const data = {
					githubToken: document.getElementById("githubToken").value,
					updateFrequency: document.getElementById("updateFrequency").value
				};
				saveSettings(JSON.stringify(data));
			}
			document.getElementById("githubToken").value = githubToken;
			document.getElementById("updateFrequency").value = updateFrequency;
		</script>
	</body>
</html>
`
