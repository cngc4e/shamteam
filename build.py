import re

template = open("module.lua", "r", encoding="utf-8").read()


def getContent(match):
    return open(match.group(1), "r", encoding="utf-8").read()
    
reg = re.compile(r'@include (\S+)', re.S)
template = reg.sub(getContent, template)

with open("shamteam.lua", "w", encoding="utf-8") as f:
    f.write(template)
