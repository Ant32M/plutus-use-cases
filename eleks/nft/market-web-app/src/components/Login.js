import { Redirect } from 'react-router-dom';
import { compose, withState, withProps, withHandlers } from 'recompose';

import { withAuth } from '../helpers/withAuth';

import Loader from './Loader';
import Select from 'react-select';
import Form from 'react-bootstrap/Form';
import Button from 'react-bootstrap/Button';

import '../styles/Login.scss';

const Login = ({
  options,
  setWallet,
  onSubmit,
  errorVisibility,
  currentUser,
  currentUserFetching,
}) =>
  !currentUser ? (
    <div className='Login'>
      <h2 className='heading'>Login</h2>
      <h6 className='subheading'>
        Choose wallet and start your <br /> investigation of NFT use case
      </h6>
      <Form onSubmit={onSubmit}>
        <Form.Group controlId='formWalletId'>
          <Select
            options={options}
            onChange={(ev) => setWallet(ev.value)}
            placeholder='Select your wallet'
          />
        </Form.Group>
        <Form.Text className={`error-text ${errorVisibility && 'visible'}`}>
          Please select your wallet to login the system
        </Form.Text>
        <Button variant='secondary' type='submit'>
          Login
        </Button>
      </Form>
      {currentUserFetching && (
        <Loader disableBackground={true} text={'Login into the system...'} />
      )}
    </div>
  ) : (
    <Redirect to='/' />
  );

const enhancer = compose(
  withAuth,
  withState('wallet', 'setWallet', ''),
  withState('error', 'setError', ''),
  withProps(({ error, wallet }) => ({
    options: JSON.parse(process.env.REACT_APP_WALLETS).map((wallet) => ({
      value: wallet,
      label: wallet.name,
    })),
    errorVisibility: error && !wallet,
  })),
  withHandlers({
    onSubmit: ({ wallet, login, setError }) => (ev) => {
      ev.preventDefault();
      if (wallet) {
        setError(false);
        login(wallet);
      } else {
        setError(true);
      }
    },
  })
);

export default enhancer(Login);
