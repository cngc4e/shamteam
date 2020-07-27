import csv

str = "maps = {"
#out = open('luatbl.lua', 'w')
with open('maps.csv', 'r') as f:
    for i, row in enumerate(csv.reader(f)):
        if i == 0:
            continue
        str += "{{code={0}, hard_diff={1}, div_diff={2}, completed=0, rounds=0}},".format(row[0], row[2], row[3])

str += "}"

print(str)
