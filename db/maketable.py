import csv

str = "maps = {"
#out = open('luatbl.lua', 'w')
with open('maps.csv', 'r') as f:
    for i, row in enumerate(csv.reader(f)):
        if i == 0:
            continue
        str += "{{code={0}, hard={1}, div={2}}},".format(row[0], row[2], row[3])

str += "}"

print(str)
