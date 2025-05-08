import React from "react";
import { parseEther } from "viem";
import { useSendTransaction, useWriteContract, useAccount } from "wagmi";
import onlyswipes from "@/contracts/onlyswipes.abi.json";
import { Button } from "./ui/button";
const Buy = () => {
  const { data, error: sendError, writeContractAsync } = useWriteContract();
  const { addresses, address } = useAccount();
  console.log(addresses, address);
  return (
    <div>
      <div>buy</div>
      <Button
        type="button"
        onClick={async () =>
          writeContractAsync({
            abi: onlyswipes,
            functionName: "buyShares",
            args: [0, 0, 1, addresses[1]!], // 0 for yes, 1 for no but in vote 0 is no and 1 is yes
            address: "0xC32dCa0687e40e4B6E9d1B3Df8f9Cc1baAcD2a67",
            value: parseEther("0.0001"),
          })
        }
      >
        buy
      </Button>
      <div>{data && "Transaction sent successfully! 🎉"}</div>
      <div>{data}</div>
      {sendError && <div>{JSON.stringify(sendError)}</div>}
    </div>
  );
};

export default Buy;
