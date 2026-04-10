# 🍝 Pasta with m&m's
> 'The worst pasta I have ever eaten' - A. Einstein

## Steps
1. Boil pasta in salted water.  
2. Chop up the m&m's, sauté in olive oil.  

## Code (timer helper)

```python
import time

def pasta_timer(minutes):
    for i in range(minutes, 0, -1):
        print(f"{i} minutes to pasta")
        time.sleep(60)
    print("Pasta is ready.")

pasta_timer(minutes=10)
```
