from honda_analyzer.analysis.live_series import LiveSeriesBuffer,numeric_value

def test_live_series_is_bounded_by_time():
    b=LiveSeriesBuffer(max_seconds=5,max_points=100)
    for i in range(11): b.append(i,i*2)
    xs,ys=b.arrays()
    assert xs == [5,6,7,8,9,10]
    assert ys[-1] == 20

def test_selection_and_numeric_filter():
    b=LiveSeriesBuffer(max_seconds=100)
    for i in range(10):b.append(i,i)
    assert [s.value for s in b.between(3,5)] == [3,4,5]
    assert numeric_value('AA BB') is None
    assert numeric_value(12) == 12.0
