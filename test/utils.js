const { BigNumber } = require('ethers')

module.exports.getEventArgs = async (fn, event, firstEvent = true) => {
  const tx = await fn;
  const receipt = await tx.wait()
  const events = receipt.events.filter(x => x.event === event)
  if (events && events.length) {
    if (firstEvent) {
      return events[0].args
    } else {
      return events.map(e => e.args)
    }
  } else {
    return []
  }
}

module.exports.random32 = () => BigNumber.from('0x' +
  Array(32).fill(0)
    .map(x => Math.floor(Math.random() * 256).toString(16))
    .join(''))
