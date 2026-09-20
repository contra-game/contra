## Токен-бакет на отправителя: входящие RPC от одного игрока не должны
## превращаться в поток эффектов и звуков на чужих машинах.
##
## per_second — установившаяся частота, burst — запас на честный залп
## (дробовик, серия из автомата, догоняющие пакеты после лага).
class_name RateLimiter
extends RefCounted

var _per_second: float
var _burst: float
var _buckets: Dictionary = {}          # id -> {"left": float, "at": float}

func _init(per_second: float, burst: float) -> void:
	_per_second = per_second
	_burst = burst

func allow(id: int) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var bucket: Dictionary = _buckets.get(id, {"left": _burst, "at": now})
	bucket.left = minf(_burst, float(bucket.left) + (now - float(bucket.at)) * _per_second)
	bucket.at = now
	var ok: bool = bucket.left >= 1.0
	if ok:
		bucket.left = float(bucket.left) - 1.0
	_buckets[id] = bucket
	return ok
