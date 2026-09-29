from honda_analyzer.protocol.elm327 import ElmPromptFramer

def test_golden_capture_prompt_fragmentation_regression():
    # Small anonymous golden stream; future vehicle captures can be added under tests/golden/.
    f=ElmPromptFramer(); out=[]
    for p in [b'41 0C 0F ',b'A0\r',b'>'] : out += f.feed(p)
    assert len(out)==1 and '41 0C 0F A0' in out[0].text
