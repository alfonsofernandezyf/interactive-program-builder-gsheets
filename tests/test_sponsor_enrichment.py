from backend.app import _enrich_sessions_with_sponsor_logos

def test_enrich_by_id():
    program = { "oct_16": [ {"id":"x-1","title":"Talk A","time":"10:00","sponsor_id":"sp01"}, {"id":"x-2","title":"Talk B","time":"11:00"} ] }
    other = { "sponsors": [ {"id":"sp01","name":"ACME","logo":"https://cdn/logo-acme.png"}, {"id":"sp02","name":"Globex","logo":"https://cdn/logo-globex.png"} ] }
    _enrich_sessions_with_sponsor_logos(program, other)
    assert program["oct_16"][0]["sponsor_logo"] == "https://cdn/logo-acme.png"
    assert "sponsor_logo" not in program["oct_16"][1]

def test_enrich_by_name():
    program = { "oct_16": [ {"id":"x-1","title":"Talk A","time":"10:00","sponsor":"Globex"} ] }
    other = { "sponsors": [ {"id":"sp01","name":"ACME","logo":"https://cdn/logo-acme.png"}, {"id":"sp02","name":"Globex","logo":"https://cdn/logo-globex.png"} ] }
    _enrich_sessions_with_sponsor_logos(program, other)
    assert program["oct_16"][0]["sponsor_logo"] == "https://cdn/logo-globex.png"
