local Rng = {}
Rng.__index = Rng

function Rng.new(seed)
    assert(type(seed) == 'number' and seed == math.floor(seed), 'Random seed must be an integer')
    return setmetatable({state = seed % 2147483646 + 1}, Rng)
end

function Rng:unit()
    self.state = self.state * 16807 % 2147483647
    return (self.state - 1) / 2147483646
end

function Rng:integer(maximum)
    assert(maximum >= 1 and maximum == math.floor(maximum), 'Empty random candidate set')
    return math.floor(self:unit() * maximum) + 1
end

function Rng:weighted(rows)
    local total = 0
    for _, row in ipairs(rows) do
        assert(type(row.weight) == 'number' and row.weight > 0, 'Random weight must be positive')
        total = total + row.weight
    end
    assert(total > 0, 'Empty weighted candidate set')
    local value = self:unit() * total
    for _, row in ipairs(rows) do
        value = value - row.weight
        if value < 0 then return row end
    end
    return rows[#rows]
end

function Rng:shuffle(rows)
    for index = #rows, 2, -1 do
        local other = self:integer(index)
        rows[index], rows[other] = rows[other], rows[index]
    end
    return rows
end

return Rng
