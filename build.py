import re

template = open("module.lua", "r", encoding="utf-8").read()

def getContentFromFile(match):
    return open(match.group(1), "r", encoding="utf-8").read()

reg = re.compile(r'@include (\S+)', re.S)
def expand(content):
    if '@include' in content:
        print("Aa")
        content = reg.sub(getContentFromFile, content)
        return expand(content)
    else:
        return content

template = expand(template)

with open("shamteam.lua", "w", encoding="utf-8") as f:
    f.write(template)
