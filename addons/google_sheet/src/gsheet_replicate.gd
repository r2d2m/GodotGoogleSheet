extends Reference

#warning-ignore:unused_signal
signal complete(name, dict)
#warning-ignore:unused_signal
signal allset
#warning-ignore:unused_signal
signal stage_changed
#warning-ignore:unused_signal
signal steps_changed
#warning-ignore:unused_signal
signal max_steps_changed

# google API service
# pros: reliable
# cons: redundant bytes, unpredictable bytes length
class Host extends Reference:
	var port = 80
	var field = "dict"
	var address = "spreadsheet.google.com"
	var uri = "/feeds/list/%s/%d/public/values?alt=json"

# gsx2json API service
# pros: less bytes, predictable bytes length
# cons: self-host
# https://github.com/deflinhec/gsx2json
class Gsx2JsonHost extends Host:
	func _init(new_address: String, new_port: int):
		port = new_port
		address = new_address
		field = "rows"
		uri = "/api?id=%s&sheet=%d&columns=false"

# gsx2jsonpp API service
# pros: less bytes, predictable bytes length
# cons: self-host
# https://github.com/deflinhec/gsx2jsonpp
class Gsx2JsonppHost extends Host:
	func _init(new_address: String, new_port: int):
		port = new_port
		address = new_address
		uri = "/api?id=%s&sheet=%d&columns=false&rows=false"

const headers = ["User-Agent: Pirulo/1.0 (Godot)","Accept: */*"]

# Debugger is not capable of debugging thread process.
const use_thread: bool = true

enum JOB { LOAD = 0, HTTP = 1 }

enum STAGE { NONE, LOAD, DOWNLOAD, COMPLETE }

var host : Host = Host.new()
var mask: int = 0 setget , _get_mask
var stage: int = STAGE.NONE setget _set_stage, _get_stage
var steps: int = 0 setget _set_steps, _get_steps
var max_steps: int = 0 setget _set_max_steps, _get_max_steps

var _sem: Semaphore
var _mutex: Mutex
var _thread: Thread
var _queue: Array
var _files: Array

# enfroce an array object to dictionary
static func array2dict(array) -> Dictionary:
	if array is Dictionary:
		return array
	var dict: Dictionary = {}
	for row in array:
		var key = row.keys()[0] 
		dict[row[key] as String] = row
	return dict 


# sanitize data if directly response from spreadsheet.google.com
static func parse(json: JSONParseResult) -> JSONParseResult:
	var data : Dictionary = json.result
	if data and data.has("feed") and data["feed"].has("entry"):
		var rows = {}
		var response = {}
		for entry in data["feed"]["entry"]:
			var pkey = 0
			var new_row = {}
			var keys = entry.keys()
			for key in keys:
				if not key.begins_with("gsx$"):
					continue
				var name = key.substr(4)
				var value = entry[key]["$t"]
				if pkey == 0 and value.is_valid_integer():
					pkey = value.to_int()
				if name.begins_with("noex"):
					continue
				new_row[name] = value
				if value.is_valid_integer():
					new_row[name] = value.to_int()
				elif value.empty():
					new_row[name] = 0
			rows[pkey] = new_row
		response["dict"] = rows
		json.result = response
	return json


func start(array: PoolIntArray = [JOB.LOAD, JOB.HTTP]) -> void:
	for v in array: 
		mask = mask | (1 << v)
	if not use_thread:
		call_deferred("_thread_func", 0)
	elif not _thread.is_active():
		_thread.start(self, "_thread_func", 0)
	yield(self, "allset")
	if use_thread and _thread.is_active():
		_thread.wait_to_finish()


func get_progress() -> float:
	var progress: float = 0.0
	_lock("get_progress")
	if max_steps != 0 and steps != 0:
		progress = float(max_steps) / float(steps)
	_unlock("get_progress")
	return progress


func _lock(_caller) -> void:
	if not use_thread:
		return
	_mutex.lock()


func _unlock(_caller) -> void:
	if not use_thread:
		return
	_mutex.unlock()


func _post(_caller) -> void:
	if not use_thread:
		return
	_sem.post()


func _wait(_caller) -> void:
	if not use_thread:
		return
	_sem.wait()


func _init(files: Array, new_host: Host = null) -> void:
	host = new_host if new_host else host
	if use_thread:
		_mutex = Mutex.new()
		_sem = Semaphore.new()
		_thread = Thread.new()
	_init_queue(files)


func _init_queue(files: Array) -> void:
	for info in files:
		var http = HTTPClient.new()
		http.set_meta("path", info[0])
		http.set_meta("id", info[1])
		http.set_meta("sheet", info[2])
		_queue.push_back(http)
		
		var file = File.new()
		if file.file_exists(info[0]):
			file.set_meta("path", info[0])
			file.set_meta("id", info[1])
			file.set_meta("sheet", info[2])
			file.open(info[0], File.READ)
			_files.push_back(file)
		else:
			print("INFO: Require download: %s" % [info[0]])


func _thread_func(_u) -> void:
	if self.mask & (1 << JOB.LOAD) != 0:
		self.stage = STAGE.LOAD
		_load_process()
	if self.mask & (1 << JOB.HTTP) != 0:
		self.stage = STAGE.DOWNLOAD
		_http_process()
	self.stage = STAGE.COMPLETE
	call_deferred("emit_signal", "allset")


func _load_process() -> void:
	self.steps = 0
	self.max_steps = _files.size()
	while not _files.empty():
		var file: File = _files[0]
		var buffer: String = file.get_as_text()
		var json = JSON.parse(buffer)
		var path = file.get_meta("path")
		self.steps += 1
		call_deferred("emit_signal", "complete", path, json.result)
		print("INFO: %s : %s" % [path, String.humanize_size(buffer.length())])
		_files.erase(file)
		file.close()


func _http_process() -> void:
	var queue: Array
	self.steps = 0
	self.max_steps = 0
	while not _queue.empty():
		var http: HTTPClient = _queue[0]
		match http.get_status():
			HTTPClient.STATUS_DISCONNECTED:
				if http.connect_to_host(host.address, host.port) != OK:
					print("WARN: STATUS_DISCONNECTED %s:%d"
						% [host.address, host.port])
					_queue.erase(http)
			HTTPClient.STATUS_CONNECTING:
				http.poll()
			HTTPClient.STATUS_RESOLVING:
				http.poll()
			HTTPClient.STATUS_CONNECTED:
				var id: String = http.get_meta("id")
				var sheet: int = http.get_meta("sheet")
				var uri: String = host.uri % [id, sheet]
				if http.request(HTTPClient.METHOD_GET, uri, headers) != OK:
					print("WARN: STATUS_CONNECTION_ERROR %s:%d"
						% [host.address, host.port])
					_queue.erase(http)
			HTTPClient.STATUS_REQUESTING:
				http.poll()
			HTTPClient.STATUS_BODY:
				_queue.erase(http)
				if not http.is_response_chunked():
					self.max_steps += http.get_response_body_length()
				if http.has_response():
					queue.push_back(http)
			_:
				print("ERRR: HTTP status %d %s:%d"
						% [http.get_status(), host.address, host.port])
				_queue.erase(http)
	_queue = queue
	while not _queue.empty():
		var binaries: PoolByteArray
		var http: HTTPClient = _queue[0]
		while http.get_status() == HTTPClient.STATUS_BODY:
			# While there is body left to be read
			http.poll()
			# Get a chunk.
			var chunk = http.read_response_body_chunk() 
			if http.is_response_chunked():
				self.max_steps += chunk.size()
			self.steps += chunk.size()
			if chunk.size() == 0:
				# Got nothing, wait for buffers to fill a bit.
				OS.delay_usec(1000)
			else:
				# Append to read buffer.
				binaries = binaries + chunk
		var path = http.get_meta("path")
		print("INFO: %s : %s" % [path.get_file(), 
				String.humanize_size(binaries.size())])
		var json = parse(JSON.parse(binaries.get_string_from_utf8()))
		if json.result.has("error"):
			print("WARN: %s %s" % [json.result["error"], path])
		elif json.result.has(host.field):
			var file = File.new()
			file.open(path, File.WRITE)
			var dict = array2dict(json.result[host.field])
			call_deferred("emit_signal", "complete", path, dict)
			file.store_string(JSON.print(dict, " "))
			file.close()
		else:
			print("WARN: %s %s" % [path, json.result])
		_queue.erase(http)
		print("INFO: Total bytes downloaded: %s/%s" % [
				String.humanize_size(self.steps), 
				String.humanize_size(self.max_steps)])


func _set_stage(new_value: int) -> void:
	_lock("_set_stage")
	if stage != new_value:
		call_deferred("emit_signal", "stage_changed", new_value)
	stage = new_value
	_unlock("_set_stage")


func _get_stage() -> int:
	var value: int = 0
	_lock("_get_stage")
	value = stage
	_unlock("_get_stage")
	return value


func _set_steps(new_value: int) -> void:
	_lock("_set_steps")
	if steps != new_value:
		call_deferred("emit_signal", "steps_changed", new_value)
	steps = new_value
	_unlock("_set_steps")


func _get_steps() -> int:
	var value: int = 0
	_lock("_get_steps")
	value = steps
	_unlock("_get_steps")
	return value


func _set_max_steps(new_value: int) -> void:
	_lock("_set_max_steps")
	if max_steps != new_value:
		call_deferred("emit_signal", "max_steps_changed", new_value)
	max_steps = new_value
	_unlock("_set_max_steps")


func _get_max_steps() -> int:
	var value: int = 0
	_lock("_get_max_steps")
	value = max_steps
	_unlock("_get_max_steps")
	return value


func _get_mask() -> int:
	var value: int = 0
	_lock("_get_mask")
	value = mask
	_unlock("_get_mask")
	return value
