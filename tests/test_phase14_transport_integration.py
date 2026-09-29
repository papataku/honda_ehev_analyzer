import asyncio, json
from honda_analyzer.transport.elm_simulator import ResilientElmSimulatorTransport, ElmSimulatorProfile, LinkFaultPlan
from honda_analyzer.analysis.integration_capture import run_capture_sequence, write_golden_capture

def run(c): return asyncio.run(c)

def test_fragment_merge_and_duplicate_still_reaches_prompt():
    async def case():
        t=ResilientElmSimulatorTransport(ElmSimulatorProfile(fragment_sizes=(1,2,3)), fault_plan=LinkFaultPlan(merge_fragments_on={0}, duplicate_on={1}))
        steps=await run_capture_sequence(t,['ATI','ATDP'],timeout=.5)
        assert steps[0].success and 'ELM327' in steps[0].text
        # duplicate is intentionally pathological; parser must at least terminate at prompt.
        assert len(steps)==2
    run(case())

def test_timeout_is_recorded_and_next_command_can_continue():
    async def case():
        t=ResilientElmSimulatorTransport(fault_plan=LinkFaultPlan(timeout_on={0}))
        steps=await run_capture_sequence(t,['ATI','ATDP'],timeout=.03)
        assert steps[0].error=='TIMEOUT'
        assert steps[1].success and 'ISO 15765-4' in steps[1].text
    run(case())

def test_disconnect_reconnect_and_golden_capture(tmp_path):
    async def case():
        t=ResilientElmSimulatorTransport(fault_plan=LinkFaultPlan(disconnect_on={1}))
        steps=await run_capture_sequence(t,['ATI','ATDP','ATDPN'],timeout=.5,reconnect=True)
        assert steps[0].success
        assert steps[1].error.startswith('DISCONNECT:')
        assert steps[2].success and 'A7' in steps[2].text
        p=tmp_path/'capture.json'; h=write_golden_capture(p,steps)
        doc=json.loads(p.read_text()); assert doc['synthetic'] is True and len(h)==64 and len(doc['steps'])==3
    run(case())
