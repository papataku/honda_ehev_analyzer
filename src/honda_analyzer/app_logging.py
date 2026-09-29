import logging
from pathlib import Path

def configure(path):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    logging.basicConfig(filename=p,level=logging.INFO,format='%(asctime)s %(threadName)s %(levelname)s %(name)s %(message)s',force=True)
    return logging.getLogger('honda_analyzer')
