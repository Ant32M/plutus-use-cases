import { NFTStorage } from 'nft.storage';
import { IPFS_API_TOKEN } from '../helpers/constants';
import { fetchStatus } from './status';
const API_URL = process.env.REACT_APP_API_URL;

export async function fetchAddToken(wallet, data) {
  const clientIPFS = new NFTStorage({ token: IPFS_API_TOKEN });
  const cpFile = await clientIPFS.storeBlob(data.cpFile);
  const response = await fetch(`${API_URL}/${wallet.id}/endpoint/create`, {
    method: 'POST',
    headers: {
      'Content-type': 'application/json',
    },
    body: JSON.stringify({ ...data, cpFile }),
  });

  if (response.status === 200) {
    return await fetchStatus(wallet, 'Created');
  } else {
    return {
      error: 'Unable to add token',
    };
  }
}

export async function fetchMyTokens(wallet) {
  const response = await fetch(
    `${API_URL}/${wallet.id}/endpoint/userNftTokens`,
    {
      method: 'POST',
      headers: {
        'Content-type': 'application/json',
      },
      body: JSON.stringify([]),
    }
  );

  if (response.status === 200) {
    return await fetchStatus(wallet, 'Tokens');
  } else {
    return {
      error: 'Unable to fetch tokens',
    };
  }
}
